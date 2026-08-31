Status: needs-triage
Blocked by: 02

# 05: Reboot cleanly instead of cutting power when a node detects it is isolated

## The problem

When the watchdog decides a node is unhealthy, it stops writing to `/dev/watchdog` and
the board's timer chip resets it. That is the equivalent of pulling the power cable —
no shutdown, no warning to anything running.

For a hung kernel that is the only option available, and it should stay. But losing the
network is not a hung kernel. The machine is fine; it just cannot talk to anything.
Killing it outright costs us three things:

1. **We lose the logs, so we cannot tell why it happened.** This is why the 15:00
   reboot on 2026-08-27 is still unexplained. Ticket 01 makes journald write to the
   SSD, which helps, but a power cut still loses whatever has not been flushed yet.
2. **containerd never saves its state.** This is the suspected cause of ticket 04 —
   the seven pods that would not restart after the reboot. If that link is real, this
   ticket is the actual fix for that outage, not a nice-to-have.
3. **Filesystems get no clean unmount.** Repeated hard resets on ext4 over LVM is a
   slow way to discover a journal replay bug.

Ticket 02 gives us the missing piece: `/usr/local/sbin/node-isolation-check` is the
first point where the node knows, reliably and in software, that it is isolated. At
that moment it is perfectly capable of rebooting itself properly.

## What must not change

The hardware watchdog stays. If the kernel hangs, no script can run, and the timer chip
is the only thing that can recover the machine. This ticket only changes what happens
in the case where software *is* still running and has decided it is cut off.

Which means the graceful path needs a bound: if the clean reboot hangs, the hardware
timer must still fire and reset the board. Otherwise we have swapped a recoverable
failure for a node that hangs forever.

## Options to evaluate

**A — use the watchdog daemon's `repair-binary`.** The daemon can run a script instead
of resetting when a check fails. That script could try to fix the network first (bounce
the interface, renew DHCP), and only reboot if the node is still isolated afterwards.
Fits what is already there, no new services. One catch from the man page: with
`repair-timeout = 0` the hardware timer keeps running during the repair, so the board
resets mid-repair. Any repair needs a non-zero timeout it can finish inside.

Worth noting this option can do something the others cannot: fix the connection without
rebooting at all, leaving the pods running.

**B — a separate systemd timer.** Runs the same isolation check on a schedule and calls
`systemctl reboot` after N consecutive failures. The hardware watchdog goes back to
doing only what it is good at. Cleaner split, but two things now run the check — share
one script between them rather than writing it twice.

**C — stop k3s before rebooting.** Whichever of A or B we pick, stop `k3s-node` first so
containerd shuts down properly. This is the part most likely to prevent ticket 04.

One thing to verify: an isolated node cannot reach the API server, so it cannot cordon
or drain itself, and `systemctl stop k3s-node` may hang waiting on API calls that will
never answer. If it hangs, this is exactly the case that has to fall through to the
hardware timer. Test it on a node with its network pulled.

## Questions to answer

- **Does a clean reboot actually prevent the ticket 04 pod wedge?** Reboot one node
  with `systemctl reboot`, force-reset another, compare which comes back with all pods
  running. This is the single most valuable thing in this ticket — it settles whether
  05 fixes 04 or merely tidies up. Record the result in both tickets.
- How long should the node stay isolated before it acts? Long enough to outlast a
  router reboot, short enough that Longhorn volumes are not stranded. Kubernetes'
  own eviction timeout of ~300s is the obvious reference point.
- Should it try to repair the network before rebooting at all?
- If the clean reboot hangs, what catches it, and after how long?

## Acceptance criteria

- A recommendation naming one option, and why the others were rejected.
- The clean-vs-hard reboot test run, with the pod recovery result written down.
- Proof the hardware watchdog still catches a real kernel hang after the change —
  `echo c > /proc/sysrq-trigger` on a node that can afford it. The node must reset.
- The decision recorded in `docs/adr/`, because it sets the standing rule for which
  failures are handled in software and which are left to the hardware.

## Comments

### 2026-08-30 — clean reboot half of the shared experiment

`systemctl reboot` on `lib-potato-04` (run as part of ticket 01). All pods returned
`Ready` on the same node with no intervention. Full detail in ticket 04's comments.

For this ticket's purposes: the clean path is confirmed safe on a node that previously
wedged. That is the necessary precondition for this ticket to be worth building — if a
clean reboot had wedged the node too, converting the hard reset into a graceful one would
buy nothing.

It is not yet sufficient. The force-reset comparison has not been run, so we still cannot
say the hard reset causes the ticket 04 wedge, only that a clean reboot avoids it. Ticket
06's acceptance test (`echo b > /proc/sysrq-trigger`) is that comparison — run it and
record the pod state on the way back up.

### Premise correction — the watchdog does not cut power on a failed check

This ticket opens with "it stops writing to `/dev/watchdog` and the board's timer chip
resets it. That is the equivalent of pulling the power cable." The logs from
`lib-potato-04` boot `-1` show that is **not** what happens on a failed check:

```
18:06:28  watchdog[1889]: Retry timed-out at 75 seconds for 192.168.1.1
18:06:28  watchdog[1889]: shutting down the system because of error 101 = 'Network is unreachable'
18:06:29  systemd[1]: Received SIGTERM from PID 1889 (watchdog)
```

The daemon asks systemd to shut down. It is a software-initiated reboot already. The
hardware timer is the backstop for the case where the daemon itself dies or the kernel
hangs — not the normal path for a check failure.

Also from the same startup banner: `watchdog now set to 60 seconds`. So the daemon has a
60s hardware timeout running *during* its own shutdown. If that shutdown overruns 60s,
the board is reset mid-shutdown — which is the plausible route to the ticket 04 wedge,
rather than an immediate power cut.

**What this changes:**

- Options A and B are no longer "convert a hard reset into a clean reboot". The reboot is
  already software-initiated. The real questions become whether the shutdown *completes*
  inside 60s, and what it does about k3s on the way down.
- **Option C is now the substance of this ticket**, not an addendum. Stopping `k3s-node`
  before the reboot is the only part that plausibly changes the containerd outcome.
- The ticket's own warning gains weight: an isolated node cannot reach the API server, so
  `systemctl stop k3s-node` may hang — and a hang here is precisely what pushes the
  shutdown past 60s into a genuine hardware reset. This is now the leading hypothesis for
  2026-08-27 and should be tested directly: pull a node's network, let the watchdog trip,
  and time the shutdown.
- On 2026-08-30 the shutdown completed cleanly, but boot `-1` was only 106s old so k3s
  had barely started. That is not a representative test.
