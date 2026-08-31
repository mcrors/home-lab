Status: resolved

# 01: Disable armbian-ramlog and move /var/log to the SSD

## Context

`armbian-ramlog` is active on all 8 SBC nodes (`lib-nuc-01` is the only node without
it). It mounts a 50MB zram device over `/var/log` and only flushes to disk on a clean
shutdown. It ships enabled by default to spare SD cards from write wear; these nodes
boot from `ssd_vg-root_lv`, so it protects hardware we do not have.

It costs us three things, all of which bit during the 2026-08-27 incident:

1. **A hard 47MB cap on `/var/log`.** The kubelet retry loop wrote 28MB of `syslog`
   in six hours (>90% of the file) and tripped `DiskWillFillSoon`.
2. **Volatile logs.** An unclean reboot loses everything since the last flush.
3. **Defeated journald persistence.** `infra/roles/common/tasks/journald.yaml` sets
   `Storage=persistent` correctly, but ramlog runs `journalctl --relinquish-var` on
   every sync (line 73 of `/usr/lib/armbian/armbian-ramlog`), which returns journald
   to volatile mode. On lib-pi-01 journald was writing 28MB to `/run/log/journal`
   (tmpfs) and `journalctl --list-boots` knew about exactly one boot.

This is why `journalctl -b -1` was empty when we needed the cause of the 15:00 reboot.
Fixing this first makes every other ticket here diagnosable.

## How ramlog actually works

Read before implementing — the mount topology is not obvious:

```sh
start)
    mount --bind $RAM_LOG $HDD_LOG      # bind /var/log -> /var/log.hdd
    mount --make-private $HDD_LOG
    mount -o discard,... $rd $RAM_LOG   # then mount zram over /var/log
    syncFromDisk

stop)
    syncToDisk                          # rsync zram -> real dir via the bind
    umount -l $RAM_LOG
    umount -l $HDD_LOG
```

So `/var/log.hdd` is not a separate directory — it is the **real on-disk `/var/log`**
exposed via bind mount while zram shadows the mountpoint. Once both mounts are gone,
the content is already in place at `/var/log`. **No copying is required.**

Confirmed on lib-pi-01:

```
/dev/mapper/ssd_vg-root_lv on /var/log.hdd type ext4 (rw,noatime,stripe=8191)
/dev/zram1                 on /var/log     type ext4 (rw,nosuid,nodev,noexec,...)
```

## Scope

Add `infra/roles/common/tasks/ramlog.yaml` and include it from
`infra/roles/common/tasks/main.yml` **before** the journald include, so that
`journald.yaml` creates `/var/log/journal` on the SSD rather than inside zram.

The task must:

1. `stat` `/etc/default/armbian-ramlog` and no-op when absent, so the role stays safe
   on `lib-nuc-01` and any future non-Armbian node. The common playbook runs against
   `all_nodes`.
2. **Stop the service before disabling it.** Ordering is load-bearing: line 16 of the
   script is `[ "$ENABLED" != true ] && exit 0`, so setting `ENABLED=false` first turns
   `stop` into a no-op that skips `syncToDisk` and both `umount` calls, stranding the
   live logs in zram and leaving the mounts in place.
3. Set `ENABLED=false` in `/etc/default/armbian-ramlog`.
4. `systemctl disable armbian-ramlog`.
5. Assert `/var/log` is no longer a zram mount (`findmnt -no SOURCE /var/log`) and that
   `/var/log.hdd` is unmounted. Fail loudly rather than continuing on a half-migrated
   node.
6. Replace `/var/log/journal` if it is a symlink. ramlog creates
   `/var/log/journal -> /var/log.hdd/journal`; with the bind mount gone that symlink
   dangles. It must become a real directory, `root:systemd-journal`, mode `2755`.
7. Notify the existing `restart journald` handler.

Leave zram swap alone — `zram0` is swap and is unrelated. Only `zram1` (label
`log2ram`) is the log device, and `ENABLED=false` is enough to stop it being mounted.

## Acceptance criteria

- `findmnt /var/log` returns nothing (no zram, no tmpfs) on every SBC node.
- `df /var/log` reports `ssd_vg-root_lv`.
- `/var/log/journal` is a real directory on the SSD, not a symlink.
- `journalctl --header | grep 'File path'` shows paths under `/var/log/journal`, not
  `/run/log/journal`.
- Reboot a node. `journalctl --list-boots` lists **at least two** boots afterwards.
  This is the acceptance test that matters — everything else is a proxy for it.
- Re-running the play is idempotent and reports no changes on the second pass.
- `docs/adr/` gains a short record: why ramlog was disabled, and the SD-wear rationale
  that no longer applies.

## Comments

### 2026-08-30 — implemented, not yet run against hardware

`infra/roles/common/tasks/ramlog.yaml` added and included from `main.yml` before the
journald include. `docs/adr/0001-disable-armbian-ramlog.md` written (first ADR in the
repo — `docs/adr/` did not exist). `ansible-playbook --syntax-check` passes; nothing has
been run against a node.

Two things were added beyond the ticket as written:

1. **`restart rsyslog` handler.** The ticket only notifies `restart journald`. ramlog
   unmounts lazily (`umount -l`), which detaches the mount but leaves already-open file
   handles pointing into the detached zram device. rsyslog holds `/var/log/syslog`,
   `auth.log` and `kern.log` open continuously, so without a restart it keeps writing
   into the invisible device and the on-disk files silently stop growing. No error is
   reported anywhere — the same class of silent-logging failure this project exists to
   fix.

2. **`ENABLED=true` is set before the service is stopped.** The ticket correctly warns
   that disabling before stopping strands the logs, but does not say what to do about a
   node already in that state. Forcing `ENABLED=true` first means a re-run recovers a
   half-finished attempt instead of failing the assertion forever.

Both restarts fire as handlers rather than inline tasks, deliberately: journald must not
restart until `journald.yaml` has created the real `/var/log/journal`, otherwise it falls
back to volatile `/run/log/journal` — the exact state we are removing. Handlers flush at
the end of the play, which is after that point.

### Open before running

**Is `/var/log/pods` inside the zram?** Kubelet writes container stdout/stderr there and
containerd holds one open handle per running container for its lifetime. If those files
are on the zram, the lazy unmount leaves containerd writing to the detached copy while
`kubectl logs` reads the frozen rsync snapshot on the SSD — so `kubectl logs` returns
stale output for every running container and never updates, until each one restarts.
Workloads stay up; observability does not.

47MB is too small to hold pod logs for a node, and the incident notes describe 28MB of
syslog as the bulk of that filesystem, which leaves no room — so this is probably fine.
That is inference, not verification. Check first:

```sh
findmnt /var/log/pods; ls /var/log/pods | head
```

If it is on the zram, roll out node-by-node with a reboot rather than fleet-wide.

### 2026-08-30 — first run on lib-potato-04, one defect found and fixed

Mounts migrated cleanly. `findmnt /var/log` and `findmnt /var/log.hdd` both empty,
`df /var/log` on `ssd_vg-root_lv`, `/var/log/journal` a real directory
(`drwxr-sr-x`, i.e. 2755, `root:systemd-journal`) whose Mar 28 mtime confirms it is the
pre-existing on-disk directory that had been hidden under the zram.

**But journald was still writing to `/run`:**

```
File path: /run/log/journal/40bba57.../system.journal
State: ONLINE
File path: /var/log/journal/40bba57.../system.journal
State: OFFLINE
```

Restarting journald does not move it onto persistent storage.
`systemd-journal-flush.service` is what does that, and it runs once at boot and then
stays `active (exited)`, so a mid-life restart never re-triggers it. `Storage=persistent`
does not override this on its own.

Fixed by adding a `flush journal to persistent storage` handler
(`journalctl --flush`), notified alongside `restart journald`. It is defined *after*
`restart journald` in `handlers/main.yaml` because handlers run in file order, not
notification order.

Worth noting for the remaining nodes: the acceptance-test reboot would have masked this.
On a fresh boot the flush unit runs normally, so a rebooted node looks correct whether or
not the role is. The `--header` check has to happen *before* the reboot.

`lsblk` also confirms `zram1` (50M) stays allocated but unmounted until reboot, as
expected. `zram0` is swap and untouched.

### 2026-08-30 — lib-potato-04 passes all acceptance criteria

```
findmnt /var/log        -> empty
findmnt /var/log.hdd    -> empty
df /var/log             -> /dev/mapper/ssd_vg-root_lv
/var/log/journal        -> real directory, drwxr-sr-x (2755), root:systemd-journal
journalctl --header     -> all files under /var/log/journal, system.journal ONLINE
journalctl --list-boots -> 3 boots
second playbook run     -> zero changed tasks
```

Ticket 01 is done on this node. **Not yet rolled out to the other seven.**

**The rollout does not need a reboot per node.** The role restarts rsyslog and journald
and flushes the journal, which is the entire migration. The reboot in the acceptance
criteria above is a one-off proof that logs survive a restart, and it has been passed on
`lib-potato-04`. Repeating it per node adds risk (see ticket 07) and proves nothing new.
The only thing it recovers is ~50MB of zram per node, which the next natural reboot does
anyway.

Per-node verification without a reboot:

```sh
findmnt /var/log                                        # empty
journalctl --header | grep -E "^File path:|^State:"     # all /var/log/journal, ONLINE
ls -l /var/log/syslog; logger check; sleep 2; ls -l /var/log/syslog   # size grows
```

The third check matters because rsyslog failing here is silent — it keeps writing into
the detached zram through its open file handles and reports no error.

### 2026-08-30 — rolled out to all eight SBC nodes, ticket resolved

`lib-potato-01/02/03/04` and `lib-pi-01/02/03/05` all migrated and verified. Only
`lib-potato-04` was rebooted, as the one-off acceptance test.

`lib-nuc-01` has no ramlog and is correctly skipped by the task. `lib-pi-04` and
`lib-pi-06` are outside the `all_nodes` inventory group and are handled separately by the
operator.

Follow-on work now unblocked: ticket 06 (journald sync interval and the duplicate-logging
decision), and the force-reset experiment that ticket 06, 04 and 05 all depend on.

### Suggested first run

`lib-potato-04` — SBC so it has ramlog, `k3s_worker` so no control-plane exposure, and
not in the `longhorn` group so no volume replicas rebuild on the reboot.

```sh
ansible-playbook -i inventory.yaml playbooks/common.yaml --tags basic --limit lib-potato-04.home --check
```

The reboot that follows is also the clean-shutdown half of the shared 04/05 experiment.
Record which pods were on the node beforehand and whether they all came back.
