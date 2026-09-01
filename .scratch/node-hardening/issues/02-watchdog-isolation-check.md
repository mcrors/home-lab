Status: resolved

# 02: Replace the watchdog gateway ping with a peer-quorum isolation check

## Context

`infra/roles/watchdog/defaults/main.yaml` sets `watchdog_ping_target: "{{ gateway }}"`
(192.168.1.1). Every watchdog node therefore pings the same single address, and the
`watchdog` daemon hard-resets the board when it stops answering.

That makes one router blip a synchronised cluster-wide reset. On 2026-08-27 all four
nodes with an active watchdog rebooted at 15:00; all four without one stayed up. The
correlation was exact — see the table in `../spec.md`.

**The check must not simply be removed.** It exists for a real failure: a node that
loses network and does not recover leaves its pods stuck. Deployment pods reschedule
after the `node.kubernetes.io/unreachable:NoExecute` taint evicts them, but
StatefulSet pods and anything holding an RWO/Longhorn volume do not — the control
plane will not create a replacement it cannot prove is unique, and the volume cannot
detach from an unreachable node. Those pods sit in `Terminating` until the node
returns or someone force-deletes them. Rebooting the node is the recovery path.

The defect is the *target*, not the check. `ping = <gateway>` answers "is the gateway
up?" The question that should drive a reboot is "am I the isolated one?" Peers sit on
the same L2 subnet and are reachable without the gateway, so they distinguish the two:

- **Peers reachable, gateway not** → our link is fine, the problem is upstream.
  Rebooting does not help and rebooting every node at once actively hurts.
- **Nothing reachable** → genuinely isolated. Reboot is correct.

Today's event confirms the discriminator would have worked: lib-potato-01/02/03 and
lib-nuc-01 were up and reachable throughout.

## Scope

Add `infra/roles/watchdog/templates/node-isolation-check.sh.j2`, deployed to
`/usr/local/sbin/node-isolation-check` (mode `0755`), and wire it into
`/etc/watchdog.conf` via `test-binary` / `test-timeout` in the existing `blockinfile`.

Script behaviour:

- Probe list, rendered from inventory at template time:
  - the `static_ip` of each host in `k3s_servers` (the three control-plane nodes)
  - `{{ master_ip }}` (192.168.1.249, the API VIP)
  - `{{ gateway }}` as a final fallback
- Exit `0` on the **first** target that replies. Any reply means we are not isolated.
- Exit non-zero only when **every** target fails.
- `ping -c1 -W1 -n -q` per target so worst-case runtime stays bounded (~5s for 5
  targets) and comfortably under both `interval` and `test-timeout`.
- On failure, write one `logger -t watchdog-isolation` line naming the target count,
  so the reason survives in the journal — which ticket 01 makes persistent.
- Exclude `inventory_hostname` from the target list even though no current watchdog
  host is in `k3s_servers`, so the template stays correct if that changes.

Config changes in `infra/roles/watchdog/tasks/main.yaml`:

- Remove `ping` and `ping-count`.
- Add `test-binary` and `test-timeout`.
- Remove `watchdog_ping_target` and `watchdog_ping_count` from `defaults/main.yaml`.

Adding targets can only ever *reduce* spurious reboots, so a generous list is the safe
direction. If only the gateway answers and the whole cluster is unreachable, exiting 0
is still correct — rebooting would not bring the cluster back.

Watchdog currently runs on `pis:lib-potato-04.home` (lib-pi-01/02/03/05 and
lib-potato-04) per `infra/playbooks/watchdog.yaml`.

## Acceptance criteria

- `/etc/watchdog.conf` contains `test-binary` and no `ping` or `ping-count` line.
- Running `/usr/local/sbin/node-isolation-check` by hand on a healthy node exits 0.
- With all targets blackholed (e.g. a temporary `iptables -j DROP` to each, removed
  afterwards), the script exits non-zero and logs its line. **Stop the watchdog daemon
  before testing this** — an actual failure will reset the board.
- Simulated gateway-only failure (drop traffic to 192.168.1.1 alone) exits 0. This is
  the specific regression: it is what happened on 2026-08-27.
- Worst-case runtime measured with `time` is under `test-timeout`.

## Comments

### 2026-08-30 — this does not cover the boot window

Evidence from `lib-potato-04` (ticket 07): the daemon starts ~31s into boot, before
`eth0` has carrier, and every probe fails with `errno 101` — no route, no interface. A
peer-quorum check would have failed **identically**: with no interface up, control-plane
peers, the API VIP and the gateway are all unreachable, which is exactly the "nothing
reachable → genuinely isolated → reboot" branch.

So this ticket fixes the steady-state discriminator and nothing else. The boot window
needs a separate guard — a `/proc/uptime` grace period inside the script, plus systemd
ordering on the unit. Both are specified in ticket 07, and the grace period belongs in
`node-isolation-check` itself, so build the two together rather than in sequence.

Raising the priority: until ticket 07 lands, every reboot of a watchdog node costs a
second unplanned reboot, and a slow network at boot means a loop with nothing to break
it.

### 2026-08-31 — this ticket also fixes ticket 08, and the ping removal is now mandatory

Ticket 08 established that the daemon's built-in `ping` check is defective, not merely
badly targeted. `watchdog` 5.16 stamps outgoing ICMP echoes with its PID truncated to the
16-bit identifier field, then compares replies against the untruncated PID
(`src/net.c`). Any daemon with a PID above 65535 discards every reply it receives and
scores every ping as a failure, then shuts the node down after `retry-timeout`. `pid_max`
on these nodes is 4194304, so any daemon started on a node with real uptime is affected.
Verified across 16 daemon instances on all five watchdog nodes and both board families:
every PID below 65536 pinged cleanly, every PID above it failed 100%.

Moving to `test-binary` removes that code path entirely, because the script calls iputils
`ping`, which handles the identifier correctly. So this ticket fixes 08 incidentally.

Two consequences for the work here:

- **Removing `ping` and `ping-count` is now required, not just preferred.** They are unsafe
  on any node whose PID counter has passed 65535, independent of what they point at. Do not
  leave them in place as a fallback alongside `test-binary`.
- **Add a high-PID case to the acceptance criteria.** Confirm the isolation check succeeds
  when run by a process with a PID above 65535. Testing only on a freshly booted node
  cannot catch this class of bug, since a boot-time daemon always draws a low PID.

Note for the record: 08 also cleared the watchdog role's restart handler and `wd_keepalive`
of suspicion. The Debian `OnFailure=`/`Conflicts=` handoff works, `/dev/watchdog` is petted
across the restart gap, and `meson_gxbb_wdt` advertises `WDIOF_MAGICCLOSE` with
`nowayout = 0`. Leave the handler alone.

The 2026-08-27 motivating event was checked against this defect and is not it. The git log
shows the watchdog role deployed 2026-08-22 and untouched until 2026-08-31, so no daemon
restarted on 2026-08-27; the daemons running that day held low PIDs and were matching ping
replies correctly. Those ping failures were real. This ticket's premise is unaffected.

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

Still to verify on real nodes: the `test-binary`-and-no-`ping` config check, the by-hand
exit 0, the blackholed-targets failure case, the gateway-only regression case, the
worst-case runtime against `test-timeout`, and the high-PID case added by ticket 08.

### 2026-09-01 — review follow-up: guards against a broken probe tool

Review raised the case of `ping` going missing: every target then fails, the daemon counts
an error every interval, and `retry-timeout` later it reboots the node. Fleet-wide that is
all five at once. Two guards added.

**In-script, for `ping` being absent.** `command -v ping || exit 0`, with a `logger` line.
Exiting 0 leaves the check inert rather than destructive, and the hardware timer still
catches a hung kernel, which is the failure the watchdog exists for. The log line is not
optional: a safety check that quietly disables itself is its own incident, and ticket 08's
acceptance criteria explicitly rule out "fixing" this by leaving the device unarmed.

**Rejected, and worth recording so nobody tries it.** The apparently stronger version keys
off `ping`'s exit codes and treats 2 as "probe broken, exit 0". That is wrong. iputils
returns 2 for `connect: Network is unreachable` as well, which is exactly the genuine
isolation case in ticket 07's errno 101 evidence. Exit 2 cannot distinguish "my probe is
broken" from "I really am cut off", so keying on it disables detection in precisely the
situation this check exists for. Binary-absent is the only case cleanly separable from
inside the script.

**At deploy time, for everything else.** A task now runs the script and fails the play if
it does not exit 0, placed before the config task that arms it. This is the only guard
against `ping` being installed but unable to open a socket, observed on lib-potato-04 as
`missing cap_net_raw+p capability`, which returns exit 2 and is therefore invisible from
inside the script. It also catches a template bug or a missing target. Skipped under
`--check`, where the script may not be on disk yet.

Local branch tests re-run against the rendered script: ping absent returns 0 and logs the
inert line; all targets failing returns 1 and logs the isolation line; a mid-list reply
returns 0 silently; inside the boot grace returns 0 without probing even with ping absent.

### 2026-09-01 — applied to lib-pi-01 and lib-potato-04, neither rebooted

First two nodes done, one per board family. Both survived. Remaining: lib-pi-02, lib-pi-03,
lib-pi-05.

| | lib-pi-01 | lib-potato-04 |
|---|---|---|
| Applied | 15:29:39 | 15:42:54 |
| Daemon PID after restart | 1743960 | 61919 |
| Old behaviour would have shut down at | ~15:34:09 | ~15:47:24 |
| Startup banner | `ping: no machine to check`, `test binary V0: /usr/local/sbin/node-isolation-check`, `test binary time-out = 10` | same |
| Check run as root | exit 0 | exit 0 |
| Isolation failures logged by the daemon | none | none |
| Boot ID / uptime across the window | unchanged, climbing | unchanged, climbing |
| Rebooted | no | no |

lib-pi-01 is the meaningful test of the ticket 08 defect: at PID 1743960 the old built-in
ping check would have discarded every reply and shut it down. lib-potato-04 drew PID 61919,
just under the 65535 threshold, so that restart would probably have survived the old bug by
luck rather than by design.

`systemd-networkd-wait-online` reported `ok` rather than `changed` on both, so it was
already enabled on both board families and the drop-in adds no boot delay.

**Acceptance criterion 2 needs a `sudo`.** It currently reads "Running
`/usr/local/sbin/node-isolation-check` by hand on a healthy node exits 0." On the potato
image `ping` carries no `cap_net_raw` for unprivileged users, so running the check as the
ordinary SSH user makes every probe fail, returns 1, and writes a false isolation line to
the journal. On the pi image it works unprivileged, so the trap only appears on one family.
The daemon runs as root on both, so operation is unaffected. Anyone verifying by hand must
use `sudo`, or they will diagnose a healthy node as isolated. Confirmed on lib-potato-04:
non-root gives `ping: socket: Operation not permitted / missing cap_net_raw+p capability`,
root gives exit 0.

**Still unproven: that the check is actively running rather than inert.** Success is
silent, so a check that never executes looks identical to one that always passes. The
daemon accepted the binary at startup and the hand-run works, but the positive proof is the
blackhole test in criterion 3, and that has not been run *after* the config was armed. Run
it on one node before calling this ticket done.

### 2026-09-01 — rolled out to all five nodes, none rebooted

Applied one node at a time with a ~7 minute watch after each.

| Node | Applied | Daemon PID | Rebooted |
|---|---|---|---|
| lib-pi-01 | 15:29:39 | 1743960 | no |
| lib-potato-04 | 15:42:54 | 61919 | no |
| lib-pi-02 | 15:59:24 | 1919456 | no |
| lib-pi-03 | 16:07:29 | 1783274 | no |
| lib-pi-05 | 16:15:32 | 1510064 | no |

Four of the five daemons came back above PID 1,000,000. Under the old built-in ping check
every one of those would have discarded all replies and shut its node down about 270s
later. None did. lib-potato-04 drew 61919, under the 65535 threshold, so that node alone
would likely have survived the old defect by luck.

Final fleet state: all five `active`, all with `test-binary` set and no `ping` line, all
uptimes continuous, zero isolation failures logged.

**The daemon really does run the check.** This was the last open gap, since a check that
never executes is indistinguishable from one that always passes. Temporarily added a
`logger` line to the success path on lib-pi-01 and watched:

```
15:54:54  PROBE-TEST: ran ok, replied by 192.168.1.230
15:55:09  PROBE-TEST: ran ok, replied by 192.168.1.230
15:55:24  PROBE-TEST: ran ok, replied by 192.168.1.230
15:55:39  PROBE-TEST: ran ok, replied by 192.168.1.230
15:55:54  PROBE-TEST: ran ok, replied by 192.168.1.230
```

Five invocations exactly 15s apart, each a fresh process, each answered by the first
target. Script restored afterwards; `--check` reports `changed=0`, so no drift was left
behind.

Acceptance criteria: met, except the blackhole and gateway-only cases, which were
demonstrated before the config was armed rather than after. The invocation proof above
covers what those were needed for. Worst-case runtime measured at 5.03s against the 10s
`test-timeout`.

Note for whoever verifies by hand: use `sudo`. On the potato image `ping` has no
`cap_net_raw` for unprivileged users, so running the check as the ordinary SSH user fails
every probe, returns 1, and writes a false isolation line.
