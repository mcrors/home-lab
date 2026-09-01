Status: resolved

# 08: Restarting the watchdog daemon reboots the node

Every `changed` result on the watchdog config task costs a reboot of all five watchdog
nodes. This makes the role expensive to run and, worse, makes operators reluctant to run
it — which is how config drift starts.

## Evidence

2026-08-31. A `playbooks/watchdog.yaml` run applying the ticket 03 config changes reset
all five watchdog hosts (lib-pi-01, lib-pi-02, lib-pi-03, lib-pi-05, lib-potato-04). The
config change itself cannot explain it: the settings in force were identical to before
except a *removed* check (`max-load-1`), and removing a check cannot reboot a board.

The operator confirms this is not new — it happens on every watchdog restart, across both
board families. It has simply never been written down.

Signature while a node is coming back: `ping` succeeds but SSH is refused, because the
kernel and network are up before sshd starts.

## How the watchdog works, in plain terms

Needed to follow the rest of this ticket.

`/dev/watchdog` is a file that stands in for a countdown timer chip physically on the
board. Writing to that file resets the countdown to full. The `watchdog` daemon writes to
it every 15 seconds. If the writes stop for 60 seconds, the chip reboots the board without
asking Linux — which is the entire point, since it still works when Linux is hung.

When a program closes that file, the countdown **keeps running** by default. That is
deliberate: a daemon that crashed is exactly what the chip exists to catch. To cancel the
countdown instead, a program writes a single character — the letter `V` — into the file
just before closing it. This is a long-standing Linux convention usually called "magic
close"; the magic is only that `V` is an arbitrary agreed-upon value.

## Mechanism

> **Superseded. Everything in this section was investigated and disproved.**
> The handler, `wd_keepalive` and magic close are all fine. Do not act on the
> "open question" below. See the 2026-08-31 investigation further down for the
> real cause.

The role's handler (`infra/roles/watchdog/handlers/main.yaml`):

```yaml
- name: restart watchdog
  shell: systemctl stop watchdog && sleep 1 && systemctl start watchdog
```

`systemctl stop watchdog` closes `/dev/watchdog`. If the daemon does not write `V` first —
or if the chip's driver ignores it — the countdown carries on with nothing resetting it,
and the board reboots roughly a minute later even though nothing was wrong. 60 seconds is
the measured timeout on both board families (ticket 03 §1, the watchdog config cleanup).

Which half fails is unknown: the daemon may not be sending `V`, or the driver may not
honour it. Establishing that is step 2 below.

The `sleep 1` between stop and start suggests someone previously hit a race here and
treated the symptom. The real gap is longer than one second anyway — the new daemon has to
start, read its config, and open the file before its first write lands.

Debian ships a service for exactly this window — `wd_keepalive`, whose entire job is to
keep petting `/dev/watchdog` while `watchdog.service` is stopped. `/etc/default/watchdog`
on these nodes already has `run_wd_keepalive=1`, so the intended bridge exists and is
evidently not taking effect. **Why not is the open question and the first thing to
establish.**

## Scope

1. **Find out what `wd_keepalive` is actually doing.** Read-only, no restarts:

   ```sh
   systemctl is-enabled wd_keepalive; systemctl is-active wd_keepalive
   systemctl cat watchdog wd_keepalive | grep -E "Conflicts|Before|After|ExecStart|WantedBy"
   journalctl -u wd_keepalive --no-pager | tail -20
   ```

   The unit is typically wired so that stopping `watchdog` starts `wd_keepalive` and vice
   versa (`Conflicts=` in both directions). If it is merely not enabled, enabling it in
   the role may be the whole fix.

2. **Confirm whether the chip will accept the `V` cancel at all.** Each board family has a
   different timer chip and a different kernel driver — `bcm2835_wdt` on the pis,
   `meson_gxbb_wdt` on the potatoes. A driver advertises whether it honours `V` via a flag
   named `WDIOF_MAGICCLOSE`. If a driver does not set it, `V` is ignored, no amount of
   politeness from the daemon helps, and `wd_keepalive` (step 1) is the only route.

   `wdctl`, a command-line tool that prints watchdog chip properties, reports that flag —
   but it cannot read the file while the daemon is holding it open, the same obstacle the
   watchdog config cleanup ticket (03 §1) hit when trying to measure the timeout. Prefer
   reading `journalctl -u watchdog` and the driver source over stopping the daemon, since
   stopping it is the very thing that reboots the node.

3. **Then fix the handler.** Do not simply swap `shell:` for `systemd: state=restarted` —
   that has the same gap. The fix has to guarantee something is petting the device
   throughout, or that the timer is genuinely cancelled across the gap.

## Acceptance criteria

- A `playbooks/watchdog.yaml` run that changes `/etc/watchdog.conf` completes with no node
  resetting. Verified on both a pi and a potato.
- `journalctl --list-boots` gains no entry on any of the five nodes across that run.
- The watchdog still works afterwards: a deliberately hung node is still reset. This must
  not be "fixed" by leaving the device unarmed.

## Interaction with other tickets

- **Ticket 07** (watchdog starts before the network, reboots ~75s into every boot) is a
  different defect in the same role, but they compound: a node rebooted by this defect can
  reboot *again* on the way back up. Fixing 07 does not fix this, and vice versa.
- **Ticket 03** is where this was found. Its config changes are applied and correct; this
  is purely about the cost of applying them.
- Until this is fixed, treat `playbooks/watchdog.yaml` as an operation with a five-node
  reboot attached. `--check --diff` previews the change without paying it.

## Comments

### 2026-08-31 — investigation: the premise in "Mechanism" above is wrong

Steps 1 and 2 are done. Both came back negative, and the real cause turned out to be a
different defect. Recording the disproof first, because the ticket as written sends the
next reader down the wrong path.

**Step 1 — `wd_keepalive` works. It is not the problem.**

The Debian handoff is wired exactly as intended and it fires. `watchdog.service` carries
`OnFailure=wd_keepalive.service` and `ExecStopPost=/bin/sh -c '[ $run_wd_keepalive != 1 ] || false'`.
With `run_wd_keepalive=1` that `ExecStopPost` deliberately exits 1, the unit enters
`failed`, and `OnFailure=` starts `wd_keepalive`. Observed on lib-pi-01, boot -1:

```
18:14:36 watchdog.service: Control process exited, code=exited, status=1/FAILURE
18:14:36 watchdog.service: Failed with result 'exit-code'.
18:14:36 watchdog.service: Triggering OnFailure= dependencies.
18:14:36 wd_keepalive[1828153]: hardware watchdog identity: Broadcom BCM2835 Watchdog timer
18:14:37 Stopping wd_keepalive.service ...        <- Conflicts=, watchdog is starting
18:14:37 Started watchdog.service
```

Something petted `/dev/watchdog` continuously across the whole gap. `wd_keepalive` being
`static` rather than `enabled` is correct — it is started by `OnFailure=`, not by a
`WantedBy` symlink. The `sleep 1` in the handler is covering the latency of that
`OnFailure` job, and it is doing so successfully.

**Step 2 — magic close is supported anyway.** `/sys/class/watchdog/watchdog0/options` on
lib-potato-04 reads `0x8180` = `WDIOF_KEEPALIVEPING | WDIOF_MAGICCLOSE | WDIOF_SETTIMEOUT`,
with `nowayout = 0`. `meson_gxbb_wdt` honours `V`. (The pi exposes only `dev` and `uevent`
under sysfs, so the flag could not be read there — moot, given step 1.)

**The nodes were never reset by the hardware timer.** They were shut down in software, by
the daemon, on its own `ping` check:

```
18:19:23 watchdog[1828220]: Retry timed-out at 270 seconds for 192.168.1.1
18:19:23 watchdog[1828220]: shutting down the system because of error 101 = 'Network is unreachable'
```

That is a graceful `shutdown`, which is exactly why the observed signature was a normal
boot (ping up, sshd not yet up) rather than the hard reset a hardware timeout produces.

**Real cause: watchdog 5.16 cannot match ICMP replies when its own PID exceeds 65535.**

`src/net.c` sets the echo identifier on send into a `uint16_t` field, which truncates the
PID to 16 bits:

```c
icp->un.echo.id = htons(daemon_pid);
```

but validates the reply against the full-width value:

```c
int rcv_id = ntohs(icp->un.echo.id);
...
if (rcv_id == daemon_pid && ...)
```

For any `daemon_pid > 65535` the comparison can never be true, so every reply is discarded
and every ping is scored as a failure. `pid_max` on these nodes is 4194304, so a daemon
started on a node with any real uptime lands above the threshold as a matter of course.

The correlation is exact across all 16 daemon instances in the journals, both board
families, with no exceptions:

| node | PID | outcome |
|---|---|---|
| lib-pi-01 | 2791 | 0 ping failures over 22 h |
| lib-pi-01 | **1828220** | 10/10 failed → shut down |
| lib-pi-01 | 3235 | 0 failures, still running |
| lib-pi-02 | 3941 | 0 failures |
| lib-pi-02 | **1791016** | 10/10 failed → shut down |
| lib-pi-02 | 1869 | 0 failures, still running |
| lib-pi-03 | 1224 | 0 failures |
| lib-pi-03 | **1818778** | 10/10 failed → shut down |
| lib-pi-03 | 2393 | 0 failures, still running |
| lib-pi-05 | 2003 | 0 failures |
| lib-pi-05 | **230252** | 10/10 failed → shut down |
| lib-pi-05 | 2072 | 0 failures, still running |
| lib-potato-04 | 2733 | 0 failures |
| lib-potato-04 | 10937 | 0 failures — *restart*, Aug 30 |
| lib-potato-04 | **72372** | 10/10 failed → shut down |
| lib-potato-04 | 5778 | 0 failures, still running |

Every instance below 65536 pings cleanly; every instance above it fails 100%.

Two controls rule out the alternatives:

- **It is not the restart itself.** lib-potato-04 PID 10937 was a mid-uptime restart from
  the Aug 30 run, drew a low PID, and pinged cleanly for 22 hours afterwards.
- **It is not a real gateway outage.** Between 18:14:52 and 18:16:45 lib-pi-01's new daemon
  failed every ping while lib-potato-04's old daemon was still pinging the same gateway
  successfully, logging nothing. No network fault can produce that.

**Consequences that change how the rest of this ticket reads:**

- The handler is not the defect and `systemd: state=restarted` was never the issue. The
  daemon restart is safe; what is unsafe is the ping check in the daemon that comes back.
- The reboot is not "roughly a minute later" via the chip. It is `retry-timeout + interval`
  later — ~270 s with the current 240 s setting — via a clean shutdown.
- Ticket 03 did not cause this and did not change it. The Aug 30 run hit the same code and
  survived only because the PIDs it drew happened to be low.
- The `ping` check has never done useful work in any restarted daemon. It is not a safety
  net that occasionally misfires; above the PID threshold it is a guaranteed node shutdown
  armed ~270 s after the daemon starts.
- **Ticket 07 needs re-reading in this light.** Its symptom — daemon starts, ping fails,
  node reboots ~75 s in — is this same ping check. At boot the PID is low, so there the
  failures are genuine (network really is not up yet). The two tickets share one component
  and any fix should address both.

Fix options are recorded in the comment below; no code changed yet.

### Resolution: ticket 02 already fixes this. No separate fix needed.

Ticket 02 replaces the daemon's built-in `ping` check with a `test-binary` peer-quorum
script. That deletes the defective code path outright: the script calls iputils `ping`,
which handles the 16-bit ICMP identifier correctly, so the PID threshold stops existing.
02 was specified before this defect was understood and fixes it incidentally.

This ticket therefore does not get its own code change. What it contributes:

1. **The diagnosis above**, which corrects the record. `wd_keepalive`, magic close and the
   handler are all fine and should not be touched.
2. **A constraint on 02 and 07**: the daemon's built-in `ping` / `ping-count` directives
   must never be reintroduced, on any board family, at any retry-timeout. They are unsafe
   on any node whose uptime has carried the PID counter past 65535. 02 already removes
   them; this is the reason they must stay removed.
3. **Urgency for 02.** Until it lands, every `changed` result on the watchdog config task
   shuts down all five nodes ~270 s later. `--check --diff` remains the safe preview.

Fold 08's acceptance criteria into 02 rather than verifying them separately:

- A `playbooks/watchdog.yaml` run that changes `/etc/watchdog.conf` completes with no node
  shutting down, verified on both a pi and a potato.
- `journalctl --list-boots` gains no entry on any of the five nodes across that run.
- The isolation check succeeds when run by a process with a PID above 65535. This is the
  specific regression 08 exists to prevent, and a boot-time-only test will not catch it.
  Force a high PID for the test rather than waiting for uptime to supply one.

### The 2026-08-27 event was not this defect

Checked against the git log, which settles it. The watchdog role was deployed
2026-08-22 (`a858df0`) and nothing touched it again until 2026-08-31 (`cdee18e`,
`8ca2163`). The only commits on 2026-08-27 are Jenkins docs, an alerting README and a
signal-bridge PRD. No watchdog config changed that day, so no handler fired and no daemon
restarted. The operator confirms the event happened in isolation, not during a session.

Daemons that had been running since the 2026-08-22 deployment held low PIDs, so their ping
checks were matching replies correctly. The 2026-08-27 ping failures were therefore real.
Ticket 02's reading of that event as a genuine network fault stands, and its motivating
evidence is unaffected by this ticket.
