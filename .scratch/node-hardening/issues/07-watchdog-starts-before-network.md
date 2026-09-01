Status: ready-for-agent

# 07: The watchdog reboots the node ~75s after every boot, because it starts before the network

## Evidence

Captured on `lib-potato-04` on 2026-08-30, in boot `-1` — the first boot whose logs
survived, thanks to ticket 01. A deliberate `systemctl reboot` produced *two* reboots:

```
18:04:42  boot starts
18:04:44  systemd-networkd[1164]: lo: Gained carrier        <- loopback only
18:05:13  systemd[1]: Starting watchdog.service             <- 31s after boot
18:05:13  watchdog[1889]: ping: 192.168.1.1
18:05:13  watchdog[1889]: network is unreachable (target: 192.168.1.1)
18:05:28  watchdog[1889]: network is unreachable (target: 192.168.1.1)
18:05:43  watchdog[1889]: network is unreachable (target: 192.168.1.1)
18:05:58  watchdog[1889]: network is unreachable (target: 192.168.1.1)
18:06:13  watchdog[1889]: network is unreachable (target: 192.168.1.1)
18:06:28  watchdog[1889]: network is unreachable (target: 192.168.1.1)
18:06:28  watchdog[1889]: Retry timed-out at 75 seconds for 192.168.1.1
18:06:28  watchdog[1889]: shutting down the system because of error 101 = 'Network is unreachable'
18:06:29  systemd[1]: Received SIGTERM from PID 1889 (watchdog)
```

`network is unreachable` is an immediate `errno 101` — no route, no interface — not a
ping timeout. `eth0` had not come up 106 seconds into the boot. Only `lo` had carrier.

## Why this matters more than it looks

`watchdog.service` has no ordering against the network. It starts ~31s into boot and
begins failing immediately. With `interval=15` and `retry-timeout=60` it reboots the
board 75 seconds later.

So **every reboot of a watchdog node costs two reboots**, and if the network is ever slow
to come up, this is a reboot loop with nothing to break it. Boot `0` survived only
because the interface came up faster the second time. That is a coin flip, not a design.

This was invisible before today. The evidence lived in zram and died with each reset.

Whether this contributed to 2026-08-27 is unknown, but it means any node rebooted for
this project may reboot itself again ~75s later.

## Ticket 02 does not fix this

Worth stating plainly, because it is easy to assume otherwise. The peer-quorum check in
ticket 02 would have failed **identically** here — at 18:05:13 there was no interface, so
every probe target was unreachable, control-plane peers included. "Nothing reachable" is
exactly the condition ticket 02 treats as genuine isolation and reboots for.

Ticket 02 fixes the *steady-state* discriminator. It does nothing about the boot window,
where "unreachable" means "not up yet" rather than "isolated".

## Scope

Two independent guards; do both, they fail differently:

1. **Order the unit after the network.** A drop-in for `watchdog.service`:

   ```ini
   [Unit]
   Wants=network-online.target
   After=network-online.target
   ```

   Requires the relevant wait unit to be enabled (`systemd-networkd-wait-online` or
   `NetworkManager-wait-online`). Check which is actually in use — the log shows
   `systemd-networkd` running while `infra/roles/set_static_ip` configures
   NetworkManager, so confirm which one owns `eth0` before relying on either.

2. **A boot grace period in the ticket 02 check script.** Ordering alone is not enough —
   `network-online.target` can be reached before the link is genuinely usable. Have
   `node-isolation-check` exit 0 unconditionally while `/proc/uptime` is below a
   threshold (180s is a reasonable start, comfortably past the observed 106s). A node
   that is genuinely isolated at boot gets caught on the next cycle; a node that is
   merely still starting does not get shot.

## Acceptance criteria

- `systemctl reboot` on a watchdog node produces exactly **one** boot in
  `journalctl --list-boots`, verified on both a pi and a potato.
- `journalctl -b -u watchdog` shows no `network is unreachable` lines during startup.
- A node genuinely isolated *after* boot still reboots — the guard must not disable the
  check outright.

## Comments

### 2026-09-01 — implemented, not yet applied

Code written and committed; nothing has been run against a node, so the acceptance criteria
are all still open. Changes live in `infra/roles/watchdog/`:

- `templates/node-isolation-check.sh.j2` (new), deployed to
  `/usr/local/sbin/node-isolation-check` mode 0755.
- `templates/watchdog.conf.j2`: `ping`/`ping-count` replaced by
  `test-binary`/`test-timeout`, with the reasons recorded in the file.
- `defaults/main.yaml`: `watchdog_ping_target`/`watchdog_ping_count` removed;
  `watchdog_isolation_check_path`, `watchdog_test_timeout` (10) and
  `watchdog_boot_grace` (180) added.
- `tasks/main.yaml`: deploys the script before the config that references it, writes a
  `watchdog.service.d/10-network-online.conf` drop-in, enables
  `systemd-networkd-wait-online`, and adds `iputils-ping` to the package list.
- `handlers/main.yaml`: added a `reload systemd` handler, defined before `restart watchdog`
  so it runs first. The restart handler is unchanged, with a comment explaining why the
  stop/sleep/start form is load-bearing.

Verified locally only: YAML parses, the template renders to
`TARGETS="192.168.1.230 192.168.1.231 192.168.1.232 192.168.1.249 192.168.1.1"` for a pi,
the script passes `sh -n`, and all three branches behave correctly against a stubbed `ping`
(inside grace returns 0 without probing, all-targets-fail returns 1 and logs one line, a
mid-list reply returns 0 silently).

**Rollout note.** The first apply should be safe: the config is written before the handler
fires, so the restarted daemon reads the new file and uses the script rather than the
defective built-in ping. The risk is inverted now, in that a broken or missing script would
fail every check and reboot the node after `retry-timeout`. Apply to one node first with
`--limit`, confirm `/usr/local/sbin/node-isolation-check` exits 0 by hand, then roll out.

**Scope item 1's open question is answered.** The ticket asked which stack owns `eth0`
before relying on a wait-online unit. `infra/roles/set_static_ip/templates/static-netplan.yaml.j2`
renders netplan with `renderer: networkd`, and the handler restarts `systemd-networkd`, so
`systemd-networkd` owns the interface and `systemd-networkd-wait-online` is the matching
unit. That is what `tasks/main.yaml` now enables. Determined from the repo, not from a node.

One consequence worth knowing: `systemd-networkd-wait-online` can hold boot for up to its
own timeout, 120s by default, if a configured interface never comes up. That is a slower
boot in exchange for not rebooting during it.

Status moved to `ready-for-agent`, since the question that made this `ready-for-human` is
now settled. Still to verify on real nodes: one boot per `systemctl reboot` on both a pi
and a potato, no `network is unreachable` lines at startup, and that a node isolated after
boot still reboots.
