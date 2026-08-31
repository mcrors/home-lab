Status: ready-for-human

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
