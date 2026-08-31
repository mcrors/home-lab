# Handoff — 2026-08-30 — Node resilience hardening

## Project

Home lab Kubernetes cluster (`mcrors/home-lab`). Working through the node resilience
hardening effort that came out of the 2026-08-27 incident, where a network blip rebooted
four nodes simultaneously and left seven pods dead for six hours with no alert firing.

Tickets live in `.scratch/node-hardening/` — `spec.md` plus one file per ticket under
`issues/`.

## What's been done this session

### Ticket 01 — disable armbian-ramlog ✅ RESOLVED

`armbian-ramlog` mounted a 50MB zram device over `/var/log` and only flushed to disk on a
clean shutdown, so every unclean reboot destroyed the evidence of its own cause. It exists
to spare SD cards from write wear; these nodes boot from SSD.

- New `infra/roles/common/tasks/ramlog.yaml`, included from `main.yml` **before** the
  journald include so the journal directory is created on the SSD.
- New `restart rsyslog` and `flush journal to persistent storage` handlers in
  `infra/roles/common/handlers/main.yaml`.
- `docs/adr/0001-disable-armbian-ramlog.md` — first ADR in the repo.
- Rolled out and verified on all eight cluster SBC nodes: `lib-potato-01/02/03/04`,
  `lib-pi-01/02/03/05`. `lib-nuc-01` has no ramlog and is correctly skipped.

Two things were needed beyond the ticket as written, both now in the role:

1. **rsyslog must be restarted.** ramlog unmounts lazily (`umount -l`), which detaches the
   mount but leaves open file handles pointing into the now-invisible zram. rsyslog keeps
   writing there and the on-disk files silently stop growing, with no error anywhere.
2. **journald must be explicitly flushed.** Restarting it is *not* enough — journald writes
   to the volatile `/run/log/journal` until something tells it to flush, and the unit that
   normally does that (`systemd-journal-flush.service`) runs once at boot and then stays
   `active (exited)`. `Storage=persistent` does not override this. Caught on
   `lib-potato-04`, where after the first run the `/run` journal was `ONLINE` and the SSD
   journal `OFFLINE`.

### Ticket 03 — watchdog config, partially done

- **`retry-timeout` set to 240s** (`watchdog_retry_timeout` in
  `infra/roles/watchdog/defaults/main.yaml`, written into `/etc/watchdog.conf`). Was
  unset, so the daemon's built-in 60s applied. 240s sits deliberately under Kubernetes'
  ~300s unreachable-eviction so a returning node rejoins before pods get relocated.
  Applied and verified on all five watchdog nodes.
- **`watchdog_timeout` deleted** from `infra/vars/main.yaml`. It was never written to any
  config file and had never had any effect. Both board families report a 60s hardware
  timeout against the 15s interval — a 4:1 margin — so writing it explicitly would only
  restate the driver default.

Still open in this ticket: remove `max-load-1`, and fix the duplicate `realtime` line.

## Key findings from the now-persistent logs

The log fix paid for itself within the hour. All three of these were previously
unobservable.

**1. The watchdog reboots every node ~75s after every boot.** New ticket 07.
`watchdog.service` starts ~31s into boot, before `eth0` has carrier, and every ping fails
with `errno 101` — no route, no interface. It reboots the board 75 seconds later. So one
`systemctl reboot` produces two boots, and a slow network at boot is an unbroken reboot
loop. The 240s retry-timeout mitigates but does not fix this.

**2. The watchdog does not cut power on a failed check.** It logs `shutting down the
system because of error 101` and sends SIGTERM to PID 1 — a software-initiated reboot,
with the 60s hardware timer running as a backstop *during* that shutdown. Ticket 05's
opening premise is wrong and is corrected in its comments. The live hypothesis is now that
`systemctl stop k3s-node` hangs on an isolated node (no API server to answer), pushing the
shutdown past 60s into a genuine hardware reset.

**3. Pods survive reboots fine.** `lib-potato-04` — the node that logged 1,557 failed
container creations in August — went through two consecutive reboots and every pod came
back `Ready` with no intervention. Recorded in tickets 04 and 05.

**4. Hardware timers measured** (ticket 03's blocker, previously thought to need the daemon
stopped). The daemon prints them at startup and those logs now persist:

```sh
journalctl -u watchdog --no-pager | grep -E "watchdog now set to|identity"
```

Both `Meson GXBB` and `Broadcom BCM2835` report 60s. The BCM2835 counter is physically
limited to ~16s, so the kernel is almost certainly pinging the chip on userspace's behalf
and presenting the longer timeout upward — inferred, not verified.

## Immediate next step

**Ticket 06 (journald durability) plus the force-reset experiment, together** — the
experiment *is* ticket 06's acceptance test, and it simultaneously answers the last open
question in tickets 04 and 05.

Ticket 06 needs: `SyncIntervalSec` added to the journald drop-in (currently unset, so
journald only writes to disk every 5 minutes — the minutes immediately before a crash are
exactly what gets thrown away), the size limits reviewed now that `/var/log` is a 30GB
partition rather than 47MB, and a decision on `ForwardToSyslog` (everything is currently
stored twice).

Then the test, on `lib-potato-04`:

```sh
kubectl get pods -A -o wide --field-selector spec.nodeName=lib-potato-04 > /tmp/pods-before.txt
ssh lib-potato-04.home 'logger "hardening-test-$(date +%s)"'
# wait past the new SyncIntervalSec
ssh lib-potato-04.home 'sudo sh -c "echo b > /proc/sysrq-trigger"'   # hard reset, no shutdown
# after boot
ssh lib-potato-04.home 'journalctl -b -1 | grep hardening-test'
kubectl get pods -A -o wide --field-selector spec.nodeName=lib-potato-04
```

Record the pod outcome in **both** ticket 04 and ticket 05. If pods come back clean after a
hard reset too, then the hard reset is not what wedged containerd in August and ticket 05
loses most of its justification.

## Remaining tickets

| # | File | Status | Notes |
|---|------|--------|-------|
| 01 | `issues/01-disable-ramlog.md` | resolved | Done on all eight SBC nodes. |
| 02 | `issues/02-watchdog-isolation-check.md` | ready-for-agent | Ping control-plane peers instead of the router. Does **not** cover the boot window — build with 07. |
| 03 | `issues/03-watchdog-config-cleanup.md` | needs-info | Two items left: remove `max-load-1`, dedupe `realtime`. Measurement blocker is resolved. |
| 04 | `issues/04-containerd-name-reservation-recovery.md` | ready-for-human | Open: is there a fixed containerd/k3s release; does `PodNotReady` catch both symptoms; auto-delete decision; runbook. |
| 05 | `issues/05-graceful-shutdown-on-isolation.md` | needs-triage | Premise corrected. Option C (stop `k3s-node` before reboot) is now the substance. |
| 06 | `issues/06-journald-survives-outages.md` | ready-for-agent | Unblocked by 01. Recommended next. |
| 07 | `issues/07-watchdog-starts-before-network.md` | ready-for-human | New this session. Build together with 02 — same script, same config file. |

Out of scope but worth not letting drift: the alert rules in
`docs/alerting/alerts-to-create.md` (`PodNotReady`, `NodeUnexpectedReboot`,
`MultiNodeRebootWindow`, `DeploymentReplicaMismatch`) are still unbuilt. `PodNotReady` is
the one that would have caught August in minutes rather than six hours.

## Gotchas for whoever picks this up

- **Ansible is in a virtualenv**: `workon ansible`, or `~/venvs/ansible/bin/ansible-playbook`.
  It is not on `PATH`.
- **Always pass `-i inventory.yaml`.** `infra/ansible.cfg` points `inventory` at
  `./hosts.ini`, which does not exist.
- **Always pass `--tags basic` to `playbooks/common.yaml`.** Without it you also run
  `root_storage`, `root_dir_migrate`, `boot_mount` and `set_static_ip` — root migration and
  a static IP reassignment.
- **Verify logging changes *before* rebooting, never after.** A reboot runs
  `systemd-journal-flush` normally, so a node looks correct whether or not the play is.
  This is how the flush bug nearly shipped. The check is:
  `journalctl --header | grep -E "^File path:|^State:"` — everything under
  `/var/log/journal`, `ONLINE`.
- **rsyslog failure is silent.** Confirm `/var/log/syslog` actually grows:
  `ls -l /var/log/syslog; logger check; sleep 2; ls -l /var/log/syslog`.
- **The k3s unit is `k3s-node.service`**, not `k3s-agent.service`. `systemctl is-active
  k3s-agent` returns `inactive` on a perfectly healthy node.
- **`lib-pi-04` and `lib-pi-06` are outside the `all_nodes` inventory group** and are not
  in the k3s cluster. The operator handles those separately — do not add them.
- **Rebooting a watchdog node currently costs two reboots** (ticket 07). Ticket 01 needed
  no per-node reboot; keep it that way for other work where possible.
