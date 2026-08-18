# Task: Blacklist Longhorn iSCSI Devices in multipathd

Status: DONE

Prevent `multipathd` from claiming Longhorn iSCSI block devices by adding a blacklist rule
to `/etc/multipath.conf` on lib-nuc-01. Without this, any instance-manager restart (including
upgrades) can leave workload pods stuck in `ContainerCreating`.

## Background

Longhorn uses iSCSI (via `tgt`) to expose volume block devices to the node. When new iSCSI
sessions are established (e.g. after an instance-manager restart), Linux's multipath daemon
(`multipathd`) detects the new SCSI disks and claims them as multipath devices (`/dev/mapper/mpatha`,
`mpathb`, etc.). This holds the underlying block device open, causing CSI mount to fail with
"already mounted or mount point busy".

Longhorn does not use multipath — it manages its own replication at the storage layer. The
blacklist tells `multipathd` to ignore `IET VIRTUAL-DISK` devices (the vendor/product string
used by Longhorn's iSCSI target).

## Steps

**1. Check current multipath config**

```bash
ssh lib-nuc-01 cat /etc/multipath.conf
```

**2. Add blacklist rule**

Add to `/etc/multipath.conf` (create the file if it doesn't exist):

```
blacklist {
    device {
        vendor  "IET"
        product "VIRTUAL-DISK"
    }
}
```

**3. Reload multipathd**

```bash
ssh lib-nuc-01 sudo systemctl reload multipathd
```

**4. Flush any existing Longhorn multipath devices**

```bash
ssh lib-nuc-01 sudo multipath -ll
# Identify any mpatha/mpathb devices backed by IET VIRTUAL-DISK, then:
ssh lib-nuc-01 sudo multipath -f mpatha   # repeat for each
```

## Ansible

This should be applied via Ansible to survive reimaging. Add a task to the NUC role or a
dedicated `multipath` role under `infra/roles/`:

```yaml
- name: Configure multipath blacklist for Longhorn iSCSI
  copy:
    dest: /etc/multipath.conf
    content: |
      blacklist {
          device {
              vendor  "IET"
              product "VIRTUAL-DISK"
          }
      }
  notify: reload multipathd
```

Wire into `infra/playbooks/longhorn.yaml` or `k3s.yaml` with a `multipath` tag.

## Validation

```bash
ssh lib-nuc-01 sudo multipath -ll
# Should show no IET VIRTUAL-DISK devices
```

After a test instance-manager pod bounce, confirm no `mpatha`/`mpathb` devices appear.

## Dependencies

- Task 03 (workloads back up) should be done first, so that flushing any existing devices
  doesn't disrupt running pods.
