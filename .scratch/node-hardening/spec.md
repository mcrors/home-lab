Status: ready-for-human

# Node resilience hardening

## Context

On 2026-08-27 at 15:00 a network event caused four nodes to reboot simultaneously.
Investigating that incident surfaced a chain of independent defects that amplified a
minor upstream blip into a six-hour partial cluster outage with no alert firing.

The chain, in order:

1. A transient network event made the gateway unreachable.
2. Every node running `watchdog` pings that same gateway, so all of them hard-reset
   at once. Nodes without the watchdog were unaffected — the correlation was exact:

   | Node | Boot time | Watchdog |
   | --- | --- | --- |
   | lib-potato-01 | Aug 16 | inactive |
   | lib-potato-02 | May 10 | inactive |
   | lib-potato-03 | Jul 4 | inactive |
   | **lib-potato-04** | **Aug 27 15:00** | **active** |
   | **lib-pi-01** | **Aug 27 15:00** | **active** |
   | **lib-pi-02** | **Aug 27 15:00** | **active** |
   | **lib-pi-03** | **Aug 27 15:00** | **active** |
   | lib-pi-05 | Aug 27 19:00 | active |
   | lib-nuc-01 | Mar 30 | inactive |

3. The hard reset left containerd holding stale sandbox and container *name
   reservations*. Kubelet could not recreate the affected pods and retried in a loop
   that never self-healed — 1,557 attempts over six hours on lib-potato-04, and
   attempt 1623 on lib-pi-01.
4. Those pods stayed in phase `Running` on a `Ready` node, so no controller replaced
   them and no existing alert matched. `metallb-controller`, `cert-manager-webhook`,
   `alertmanager` and `signal-bridge` all sat at 0/1 unnoticed.
5. The retry loop wrote ~4,400 log lines/hour into a 47MB zram `/var/log`, which
   triggered `DiskWillFillSoon` — the only alert that fired, and only as a
   second-order symptom.
6. Diagnosis of the original reboot was impossible: `armbian-ramlog` keeps logs in
   RAM and forces journald back to volatile mode, so the hard reset destroyed all
   evidence of its own cause.

Every layer failed open. The tickets here address each link independently.

## Decisions recorded

- **Keep the watchdog.** It exists because a node that loses network and does not
  recover leaves StatefulSet and Longhorn-volume pods stuck in `Terminating`
  indefinitely — the control plane will not violate at-most-one semantics, and the
  volume cannot detach from an unreachable node. That failure mode is real and the
  watchdog is the recovery path.
- **Change what it checks, not whether it checks.** `ping = <gateway>` answers "is
  the gateway up?" when the question is "am I the isolated one?" Peers on the same
  L2 subnet are reachable without the gateway and discriminate the two cases.
- **Disable `armbian-ramlog`.** It exists to spare SD cards from write wear. These
  nodes boot from SSD (`ssd_vg-root_lv`), so it protects hardware we do not have
  while capping `/var/log` at 47MB and making logs volatile.
- **Remove `max-load-1`.** High load is not a hung kernel, and Linux load average
  counts uninterruptible D-state I/O wait, so an NFS stall inflates it with no CPU
  use. Revisit with real data once journals persist.
- **All changes go through the Ansible roles.** Nothing hand-applied to nodes.

## Out of scope

- The alert rules themselves. Tracked separately in
  `docs/alerting/alerts-to-create.md` (`PodNotReady`, `NodeUnexpectedReboot`,
  `MultiNodeRebootWindow`, `DeploymentReplicaMismatch`).
- Root-causing the 15:00 network event itself. No evidence survives; ticket 01 is
  what makes the next one diagnosable.

## Tickets

| # | Title | Status | Blocked by |
| --- | --- | --- | --- |
| 01 | Disable armbian-ramlog, move `/var/log` to SSD | resolved | — |
| 02 | Replace watchdog gateway ping with peer-quorum isolation check | ready-for-agent | — |
| 03 | Fix the watchdog config defects | resolved | — |
| 04 | Pods do not come back after a node reboot | ready-for-human | — |
| 05 | Reboot cleanly instead of cutting power on isolation | wontfix | — |
| 06 | Make sure journald logs actually survive an outage | resolved | — |
| 07 | Watchdog reboots the node ~75s after every boot | ready-for-human | 02 |
| 08 | Restarting the watchdog daemon reboots the node | resolved | — |

Start with 01 and 06. Until logs survive a reboot, tickets 03, 04 and 05 are all
reasoning about evidence that the next reset will destroy.

Tickets 04 and 05 share one experiment: reboot one node cleanly, force-reset another,
and see which comes back with all its pods. That answers whether the hard reset is what
breaks the pods, and therefore whether 05 fixes 04 or just tidies up. Run it once,
record the result in both.

## Update 2026-08-30

Ticket 01 is implemented and verified on `lib-potato-04`. Logs now survive reboots, and
the first surviving boot immediately paid for the whole project — see ticket 07.

**Ticket 01 needs no per-node reboot.** The role restarts rsyslog and journald and runs
`journalctl --flush`, which is the whole job; the reboot was only ever the acceptance
test, and that has been passed once on `lib-potato-04`. Repeating it per node proves
nothing new and only reclaims ~50MB of zram, which the next natural reboot does anyway.

That removes the reason to sequence the watchdog work ahead of the rollout — the boot-time
watchdog defect (ticket 07) only bites on reboot, and there are no reboots. All remaining
nodes can take ticket 01 now, verified with `findmnt /var/log` plus
`journalctl --header` rather than with a restart.

Ticket 02 does not cover the boot window on its own — with no interface up, a peer-quorum
check fails exactly like the gateway ping did. 07 and 02 share the same script and should
be built together.

Two findings changed other tickets:

- **The watchdog does not cut power on a failed check.** It logs `shutting down the
  system` and sends SIGTERM to PID 1 — a software reboot, with the 60s hardware timer as
  a backstop running during the shutdown. Ticket 05's opening premise is corrected there;
  its option C (stop `k3s-node` first) is now the substance of that ticket.
- **Ticket 03's open question no longer needs the daemon stopped.** The startup banner
  logs `watchdog now set to <n> seconds` and the driver identity, and those logs now
  persist. One `journalctl` on a pi answers it.

Still unrun: the force-reset half of the 04/05 experiment, which is also ticket 06's
acceptance test.

## Update 2026-09-01

**Ticket 08 resolved: the watchdog's ping check is defective, not just badly targeted.**
`watchdog` 5.16 stamps outgoing ICMP echoes with its PID truncated to the 16-bit
identifier field, then compares replies against the untruncated PID (`src/net.c`). Any
daemon above PID 65535 discards every reply, scores every ping as failed, and runs a clean
shutdown after `retry-timeout`. `pid_max` on these nodes is 4194304, so a daemon restarted
on a node with real uptime always lands above the threshold; a boot-time daemon draws a low
PID and works. Verified across 16 daemon instances on all five watchdog nodes and both
board families, with no exceptions.

Consequences for the rest of the project:

- **Ticket 02 is now the fix for two tickets.** Moving to `test-binary` deletes the
  defective code path, because the script calls iputils `ping`, which handles the
  identifier correctly. Removing `ping`/`ping-count` is therefore mandatory rather than
  preferred: they are unsafe on any node past 65535 PIDs regardless of what they point at.
- **02 needs a high-PID acceptance test.** A boot-time daemon always draws a low PID, so
  testing only on a freshly booted node cannot catch this class of bug. That is precisely
  how it survived unnoticed since the role was deployed.
- **The watchdog restart handler is cleared.** The Debian `OnFailure=`/`Conflicts=` handoff
  to `wd_keepalive` fires correctly, `/dev/watchdog` is petted across the restart gap, and
  `meson_gxbb_wdt` advertises `WDIOF_MAGICCLOSE` with `nowayout = 0`. Ticket 03's closing
  comment previously blamed the handler and has been corrected in place. Do not change it.
- **The 2026-08-27 incident is unaffected.** Checked against the git log: the watchdog role
  was deployed 2026-08-22 and untouched until 2026-08-31, so no daemon restarted on
  2026-08-27 and the daemons running that day held low PIDs with working ping checks. Those
  ping failures were real. The narrative in Context above stands.

**Ticket 03 is resolved** and its `Status:` line has been corrected to match its body; all
four sections were implemented and applied on 2026-08-31.

### Open wording question in Context, above

Context items 2 and 3 describe the 2026-08-27 reboots as a "hard reset". The 2026-08-30
finding is that a failed check makes the daemon send SIGTERM to PID 1, which is a software
reboot, with the 60s hardware timer running as a backstop during the shutdown. Those two
descriptions only reconcile if shutdown overran the 60s timer and the board was cut
mid-shutdown, which would also explain the containerd name-reservation damage in item 3.
That is a plausible reading and it is **not verified**. The force-reset half of the 04/05
experiment is what would settle it. Left as written until then.

## Update 2026-09-01 (later)

**Ticket 06 closed.** `lib-pi-05` rebooted unexpectedly overnight and was triaged from the
surviving journal, which is 06's acceptance test met on a real unclean reboot. Logs now
survive resets, so the project's central goal, being able to explain the next 15:00 event,
is met.

Closed with three scope items deliberately deferred rather than done: `SyncIntervalSec` is
still unset so the 5-minute default applies, the `ForwardToSyslog` double-write question is
undecided, and the retention limits are still sized for the old ramdisk. The first carries
real diagnostic cost, since up to five minutes before an unclean reboot are still lost and
nothing relevant logs at CRIT or above. Details and the reopen trigger are in ticket 06.

## Update 2026-09-01 (ticket 05 closed wontfix)

05's opening premise was already corrected: the watchdog sends SIGTERM to PID 1 rather than
cutting power, which removed the case for its options A and B. Closing it rests on a second
point: **option C is probably already happening**, since an ordinary systemd shutdown stops
`k3s-node` with every other unit. If the pod wedge is real, the likelier cause is the
shutdown overrunning the daemon's 60s hardware window and the board being cut partway
through, which would be fixed by a `TimeoutStopSec` on `k3s-node.service` or systemd's
`RebootWatchdogSec` rather than by anything in the watchdog role.

All of that is unverified, and verifying it means pulling a production node's network to
time a shutdown. Not justified for a fault seen once. Reopen if pods fail to return after
an unclean reboot again.

This leaves the "hard reset" wording question in Context above open and now unlikely to be
answered, since the force-reset half of the 04/05 experiment will not be run deliberately.
