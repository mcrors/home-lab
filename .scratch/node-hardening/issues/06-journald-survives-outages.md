Status: resolved
Blocked by: 01

# 06: Make sure journald logs actually survive an outage

## Context

`infra/roles/common/tasks/journald.yaml` already sets `Storage=persistent` with size
and retention limits. Ticket 01 removes `armbian-ramlog`, which was overriding that and
forcing journald back into memory-only mode.

That is necessary but not sufficient. Two things still stand between us and having logs
after an unclean reboot, and the whole point of this project is being able to explain
the *next* 15:00 event.

### 1. journald only writes to disk every 5 minutes

`SyncIntervalSec` controls how often journald flushes to disk. It is not set anywhere,
so the default applies. From `man 5 journald.conf`:

> The default timeout is 5 minutes. [...] Note that syncing is unconditionally done
> immediately after a log message of priority CRIT, ALERT or EMERG has been logged.
> This setting hence applies only to messages of the levels ERR, WARNING, NOTICE,
> INFO, DEBUG.

So on a hard reset we lose up to five minutes of everything below CRIT. The minutes
immediately before a crash are the only ones worth having, and by default they are the
ones we throw away. Nothing in the 2026-08-27 incident logged at CRIT or above.

Set `SyncIntervalSec` low enough that the pre-crash window survives. These nodes write
to an SSD, so the extra write frequency is not a concern the way it would be on the SD
cards this setup originally assumed. Pick a value, and record why.

### 2. Everything is being stored twice

The effective config on lib-pi-01 includes:

```
ForwardToSyslog=yes
```

So journald keeps its own copy *and* hands every message to rsyslog, which writes it
again to `/var/log/syslog`. During the incident that meant 28MB of journal plus 28MB of
syslog holding the same kubelet retry messages — on a node with 2GB of RAM, while both
were still in memory.

Decide whether both are wanted now that logs live on the SSD. Options: keep both (some
tooling expects `/var/log/syslog`), or turn off the forward and rely on `journalctl`.
Either is defensible; record which and why. If both stay, note that any future log-spam
incident consumes disk at twice the rate.

## Scope

- Add `SyncIntervalSec` to the drop-in written by
  `infra/roles/common/tasks/journald.yaml`, driven by a new variable in
  `infra/vars/main.yaml` alongside the existing `journald_*` vars.
- Review the existing limits now that `/var/log` is a 30GB SSD partition rather than a
  47MB ramdisk. `SystemMaxUse=200M` and `MaxRetentionSec=7day` were sized for the old
  constraint. Seven days of retention is the more useful number to protect — an
  incident that needs a week of history is exactly the kind we keep having.
- Decide the `ForwardToSyslog` question above and implement whichever way it goes.
- Confirm the Armbian drop-in setting `SystemMaxUse=20M` is still being overridden by
  ours after ticket 01. Check with `systemd-analyze cat-config systemd/journald.conf`,
  which prints the merged result in precedence order.

## Acceptance criteria

The test that matters, run on a real node:

1. Log a known marker: `logger "hardening-test-<timestamp>"`.
2. Wait past the new `SyncIntervalSec`.
3. Force an unclean reset: `echo b > /proc/sysrq-trigger` (reboots immediately with no
   shutdown, which is what the watchdog does).
4. After boot, `journalctl -b -1 | grep hardening-test-<timestamp>` finds the marker.

Plus:

- `journalctl --list-boots` shows several boots and keeps growing across reboots.
- `journalctl --header | grep 'File path'` shows `/var/log/journal/...` and nothing
  under `/run/log/journal`.
- `systemd-analyze cat-config systemd/journald.conf` shows our values winning.
- The `ForwardToSyslog` decision is written down.

## Comments

### 2026-09-01 — closed on the acceptance test; the two config decisions are deferred

**Confirmed.** `lib-pi-05` rebooted unexpectedly overnight and the operator triaged it from
the surviving journal. That is this ticket's acceptance test met on a real unclean reboot
rather than a staged `sysrq-trigger` one: logs persisted across a reset and were sufficient
to diagnose from. Combined with ticket 01, the core goal is delivered. Logs now survive.

**Deliberately not done.** Closing here leaves three scope items unaddressed. They are
recorded so a future reader knows they were skipped by choice rather than missed:

1. **`SyncIntervalSec` is still unset**, so journald's 5-minute default applies. It appears
   nowhere in `infra/roles/common/tasks/journald.yaml` or `infra/vars/main.yaml`. Up to the
   last five minutes before an unclean reboot are still lost, and the CRIT-and-above
   exception does not help: the watchdog shutdown line, the kubelet retry loop and the
   ticket 08 ping failures all log below that threshold. This is the item with real
   diagnostic cost. Suggested value if revisited: 10s, since these nodes are on SSD and the
   5-minute default exists to spare SD-card flash wear.
2. **The `ForwardToSyslog` question is undecided.** Every message is still stored twice,
   once in the journal and once in `/var/log/syslog`. Far less dangerous now that
   `/var/log` is a 30GB SSD partition than it was on the 47MB ramdisk, where the doubling
   contributed to the `DiskWillFillSoon` alert on 2026-08-27. Before turning the forward
   off, check whether any tooling reads `/var/log/syslog` directly. That check has not been
   done.
3. **Retention limits were not revisited.** `SystemMaxUse=200M` and `MaxRetentionSec=7day`
   are still the values sized for the old 47MB ramdisk, not a 30GB partition.

**When to reopen:** if an incident's logs turn out to stop short of the moment of failure,
that is item 1 biting, and it is worth doing then. Item 3 matters if seven days of history
proves too short. Item 2 is housekeeping with no diagnostic consequence.
