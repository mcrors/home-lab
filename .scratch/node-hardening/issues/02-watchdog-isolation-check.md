Status: ready-for-agent

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
