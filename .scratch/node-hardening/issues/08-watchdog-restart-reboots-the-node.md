Status: needs-triage

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
