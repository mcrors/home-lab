# ADR-0002: Longhorn snapshot and backup schedule

Date: 2026-09-19
Status: Accepted

## Context

Longhorn ran with no backup target and no recurring jobs. Nine volumes totalling
37 GiB provisioned and 26.24 GiB actual, each with two replicas, were protected
by replica redundancy and nothing else. Losing the cluster meant losing all of it.

A backup target was set on 2026-09-19 to `nfs://192.168.1.96:/longhorn-backup`,
a single OMV share serving every volume. One share is correct because the target
is cluster-wide in Longhorn v1.11 and Longhorn already shards volumes beneath it
at `backupstore/volumes/<xx>/<yy>/<volume-name>/`. See
`infra/roles/longhorn_chart/files/values.yaml`.

Eight facts shaped the schedule. Each was measured on the cluster rather than
assumed.

1. **Longhorn prunes nothing by itself.** There is no age-based expiry on a
   backup target. The only mechanism that deletes anything is a recurring job's
   `retain` count, and it only touches artifacts carrying that job's own label.
2. **Snapshot space is not a constraint.** Every storage node holds over 520 GiB
   free against 26.24 GiB of actual data. `lib-nuc-01` has 713.9 GiB free.
3. **The backup target and the media store are the same machine.** Plex reads
   from `192.168.1.96:/media` and backups write to `192.168.1.96:/longhorn-backup`.
   Backup traffic competes with streaming at both the NAS and the network.
4. **The backup share is ext4.** Nothing checksums or repairs a block once
   written. The media disk is btrfs, which is irrelevant here because backups do
   not go there.
5. **Plex is the only volume that churns.** Its `volume-head` held 8.30 GiB
   written over 19 days against 4.3 GiB of live files, roughly 440 MiB per day.
   The other eight are quiet.
6. **Eight of the nine volumes hold a SQLite database. The ninth holds XML.**
   Verified by inspecting the mounted filesystems:
   `com.plexapp.plugins.library.db`, `grafana.db`, `cache.db` (ntfy),
   `kuma.db`, `account.db` (signal-cli), `sonarr.db`, `radarr.db` and
   `prowlarr.db`. Plex, uptime-kuma and the three \*arr databases carry `-wal`
   and `-shm` companions, so SQLite runs in write-ahead logging mode. Jenkins
   has no database and keeps its state as XML files under `/var/jenkins_home`.
7. **Longhorn evaluates cron in UTC.** The longhorn-manager pod has no timezone
   configured and Longhorn exposes no setting to change it.
8. **Longhorn cannot coalesce a snapshot whose only child is `volume-head`.**
   All nine volumes carry a stuck system snapshot left by a replica rebuild.
   Plex's holds 11.96 GiB and had never been purged.

## Decision

Three recurring jobs, defined in
`infra/roles/longhorn_chart/files/recurring-jobs.yaml`, all in the `default`
group and all with `concurrency: 1`.

| Job              | Task              | Cron (UTC)    | Local   | Retain |
| ---------------- | ----------------- | ------------- | ------- | ------ |
| `weekly-trim`    | `filesystem-trim` | `0 22 * * 6`  | Sat 23:00 | 0    |
| `daily-snapshot` | `snapshot`        | `0 23 * * *`  | 00:00   | 7      |
| `daily-backup`   | `backup`          | `0 1 * * *`   | 02:00   | 18     |

`daily-backup` also sets `parameters.full-backup-interval: "6"`.

`freeze-filesystem-for-snapshot` is enabled globally through
`defaultSettings.freezeFilesystemForSnapshot` in the chart values.

### Why daily backups rather than weekly

Snapshots sit on the same disks as the data, so they cover operator error and
nothing else. Two replicas cover a single disk or node failure. The backup on
the NAS is the only copy that survives losing the cluster, and running it weekly
would leave a seven-day disaster RPO while the cheap local mechanism ran nightly.

The cost is low. The first pass writes close to 26 GiB because first backups are
full. After that Longhorn ships only changed 2 MiB blocks, and six of the nine
volumes hold under 1 GiB each.

### Why retain 18 on the backup

Retention has to cover the longest period nobody is looking at the lab. Two
weeks away on holiday plus a few days to notice a problem after getting back
puts the floor above 14.

### Why retain 7 on the snapshot

Snapshots serve fast local rollback, where anything older than a week is better
served from the backup. Space does not force the number down, so 7 is chosen for
usefulness rather than economy.

### Why the crons sit where they do

The order within the night is trim, then snapshot, then backup.

Trim only ever releases blocks in `volume-head`. Once daily snapshots run, each
snapshot seals the head, so trim sees at most one day of churn no matter how long
since it last ran. Placing it an hour before the snapshot means the Saturday run
works against a nearly full day of accumulated writes.

Running trim before the backup also reduces what ships. Blocks the filesystem
freed stay allocated until a trim releases them, so trimming first means the
snapshot the backup job takes contains fewer blocks.

Backups land at 02:00 local, well clear of streaming hours, because they contend
with Plex for the same NAS and the same network path.

The two daily jobs are two hours apart because each recurring job has its own
concurrency pool and they do not throttle each other.

### Why `full-backup-interval: 6`

The parameter counts incremental backups between full ones. Six means one full,
then six incrementals, then another full, so at daily cadence a full lands every
seventh night.

A full backup overwrites blocks in the backupstore. An incremental writes only
the blocks that changed, so it leaves a corrupt block in place and every backup
referencing that block stays damaged. With the default of 0 there is never a
full, and one bad block can sit silently beneath the whole retained set until a
restore is attempted.

Because the share is ext4 on a single disk, nothing verifies or repairs those
blocks underneath Longhorn. A periodic full is the only mechanism that refreshes
them, and the interval sets how long a corrupt block can go unrepaired. At 6
that window is a week. At 18 it would be nineteen days.

The interval is deliberately not tied to `retain`. Longhorn's backupstore is a
reference-counted block store where each backup's metadata names every block it
needs, so deleting a full orphans nothing and a full does not have to stay
inside the retention window. The two numbers answer different questions.

A full re-uploads everything allocated, roughly 26 GiB, once a week.

### Why freeze the filesystem

Without it, a snapshot captures the block device mid-write and a restore is
equivalent to recovering from a power cut. The filesystem needs journal recovery
before it will mount cleanly.

Both storage shapes on these volumes benefit. The SQLite databases mostly run in
write-ahead logging mode, where the database file and its `-wal` companion have
to agree with each other, and a crash-consistent snapshot can catch the pair
mid-checkpoint. SQLite recovers from that on open because it was designed to.
Jenkins has no journal of any kind and rewrites XML configuration files in
place, so a snapshot taken mid-write can leave a truncated `config.xml` with
nothing to replay.

The cost is that writers block for the length of the freeze, which is the flush
of dirty pages plus a metadata operation on the block device. Reads are not
blocked, and Plex streams read from the NFS media mount, which is never frozen.
At 23:00 and 01:00 with `concurrency: 1` staggering the volumes, the exposure is
seconds on idle applications.

### Why `concurrency: 1` everywhere

Nine volumes on Raspberry Pi nodes sharing one 1GbE path to one NAS. None of
these jobs has a deadline, so serialising removes contention as a variable at no
cost. This single field is the whole answer to controlling load, which is why
`backup-concurrent-limit` and `concurrent-volume-backup-restore-per-node-limit`
are left at their existing values of 2 and 5.

## Consequences

- Disaster RPO drops from unbounded to 24 hours. Recovery history is 18 days of
  backups and 7 days of snapshots.
- The NAS grows by roughly 26 GiB on the first backup, then by the daily delta.
  Plex dominates that delta at around 440 MiB per day. A weekly full rewrites
  the 26 GiB, so the share sees roughly 26 GiB of upload per week on top of the
  deltas.
- The first `daily-snapshot` run unblocks the stuck system snapshots described in
  context 8. Inserting a new snapshot below the base gives Longhorn a child that
  is not `volume-head`, so it can finally coalesce. Plex should reclaim a large
  part of its 11.96 GiB.
- Snapshots and backups are filesystem-consistent rather than crash-consistent,
  at the cost of a brief write stall on each volume twice a night.
- `remove-snapshots-during-filesystem-trim` must stay `false`. If it is enabled,
  trim deletes snapshots that stand in the way of reclaiming blocks, which would
  eat the retained recovery points.
- A fixed UTC cron drifts an hour against local time when the clocks change. For
  overnight maintenance this is immaterial and is recorded so it is not mistaken
  for a fault.

## Notes

Longhorn stamped `recurring-job-group.longhorn.io/default: enabled` onto all nine
existing volumes when `weekly-trim` was created. These labels are now real
metadata on the volumes rather than an implicit default, so a future job using a
different group will need the volumes relabelled.

`persistence.recurringJobSelector` is left disabled. Whether a newly created
volume is picked up by the `default` group automatically has not been verified.
The next new PVC should be checked for the group label, and if Longhorn does not
add it, the selector is the mechanism that fixes it for new volumes.

Longhorn v1.11 removed the `backup-target` setting. The target lives in the
`BackupTarget` custom resource named `default`, fed by the chart key
`defaultBackupStore`, which renders into the `longhorn-default-resource`
ConfigMap. `defaultSettings.backupTarget` does nothing on this version.
