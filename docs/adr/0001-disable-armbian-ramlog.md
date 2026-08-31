# ADR-0001: Disable armbian-ramlog and keep /var/log on the SSD

Date: 2026-08-30
Status: Accepted

## Context

Armbian ships `armbian-ramlog` enabled by default on all eight SBC nodes
(`lib-nuc-01` is the only cluster node without it). It mounts a 50MB zram device
over `/var/log` and flushes the contents to disk only on a clean shutdown.

The rationale is SD card wear. SD cards have a limited number of write cycles and
a log directory is a continuous small-write workload, so keeping it in RAM
meaningfully extends the card's life.

**That rationale does not apply to these nodes.** They boot from
`ssd_vg-root_lv` — an LVM logical volume on an SSD — as a result of the
`root_storage` and `root_dir_migrate` roles. There is no SD card in the write
path to protect.

What it costs us instead surfaced during the 2026-08-27 incident:

1. **A hard 47MB cap on `/var/log`.** A kubelet retry loop wrote 28MB of syslog
   in six hours and tripped `DiskWillFillSoon` — an alert about a symptom several
   layers removed from the actual fault.
2. **Volatile logs.** An unclean reboot loses everything since the last sync.
3. **Defeated journald persistence.** `common/tasks/journald.yaml` sets
   `Storage=persistent`, but ramlog runs `journalctl --relinquish-var` on every
   sync, which returns journald to volatile mode. On `lib-pi-01`, journald was
   writing to `/run/log/journal` (tmpfs) and `journalctl --list-boots` knew about
   exactly one boot.

The third point is why `journalctl -b -1` was empty when we needed the cause of
the reboot. The logging system destroyed the evidence of its own failure.

## Decision

Disable `armbian-ramlog` on every node that has it, via
`infra/roles/common/tasks/ramlog.yaml`, and leave `/var/log` on the SSD.

The task is a no-op where `/etc/default/armbian-ramlog` is absent, so the
`common` role stays safe on `lib-nuc-01` and any future non-Armbian node.

Two details are load-bearing:

- **The service is stopped before it is disabled.** The stop hook is what runs
  `syncToDisk` and both unmounts, and the script exits early when
  `ENABLED != true`. Disabling first turns stop into a no-op that strands live
  logs in zram and leaves the mounts in place.
- **rsyslog and journald are both restarted.** ramlog unmounts lazily
  (`umount -l`), which detaches the mount but leaves existing file handles
  pointing into the now-invisible zram device. Without a restart, both daemons
  keep writing there and the on-disk files silently stop growing.
- **journald is then explicitly flushed.** Restarting it is not sufficient.
  journald writes to the volatile `/run/log/journal` until something tells it to
  flush, and the unit that normally does that — `systemd-journal-flush.service` —
  runs once at boot and then stays `active (exited)`, so a mid-life restart does
  not re-trigger it. `Storage=persistent` alone does not override this. Confirmed
  on `lib-potato-04`, where after the play the `/run` journal was `ONLINE` and the
  SSD journal `OFFLINE`; the handler now runs `journalctl --flush`.

`zram0` is swap and is unrelated; it stays.

## Consequences

- Logs survive an unclean reboot, which is what makes the rest of the node
  hardening work diagnosable. Ticket 06 tightens `SyncIntervalSec` so that the
  final minutes before a crash survive too.
- `/var/log` is bounded by the root filesystem (~30GB) rather than 47MB. A
  log-spam incident now costs disk instead of triggering `DiskWillFillSoon`, so
  the alerting for that failure mode has to come from the pod-level rules queued
  in `docs/alerting/alerts-to-create.md`, not from disk pressure.
- Writes to `/var/log` now hit the SSD continuously. This is the wear the
  original design avoided, and it is the correct trade on this hardware.
- The zram device stays allocated until the next reboot, holding whatever RAM it
  had. On a 2GB pi that is worth reclaiming, and the reboot is required by the
  ticket's acceptance test anyway.

## Notes

`lib-pi-04` and `lib-pi-06` are outside the k3s cluster and are not in the
`all_nodes` inventory group, so this play does not reach them. They are handled
separately.
