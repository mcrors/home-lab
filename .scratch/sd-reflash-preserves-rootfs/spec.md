Status: needs-triage

# SD reflash should not clobber the SSD rootfs

## Problem

Pi nodes boot from an SD card that carries only the boot partition (kernel, initramfs, cmdline.txt, dtbs, firmware). The actual root filesystem lives on an SSD as a logical volume (`ssd_vg/root_lv`), populated by `infra/roles/root_dir_migrate` on first provisioning.

SD cards are the weakest link in the stack. When one dies or gets corrupted (e.g. after a hardware-watchdog forced reset, as with lib-pi-02 on 2026-08-22), the natural recovery is:

1. Reflash the SD card with a fresh Pi OS image.
2. Boot the node.
3. Re-run the Ansible playbook.

Today, step 3 destroys work: `infra/roles/root_dir_migrate/tasks/main.yaml:66` runs

```
rsync -axS --delete / /mnt/new_root/
```

whenever `findmnt /` doesn't already return the SSD LV. After a reflash, `/` is the fresh SD rootfs, so the rsync fires unconditionally and wipes whatever was on the SSD's `root_lv`.

For k3s workers this is *survivable* (state lives in etcd, Longhorn replicas are on a separate LV — `ssd_vg/longhorn-lv` — and are preserved by the `-x` + `/mnt/*` exclude), but it means every SD reflash starts from an OS baseline: packages get reinstalled, host-local caches lost, node re-registers with k3s, Longhorn has to re-attach the disk. All the migration overhead runs again for no reason.

## Goal

A reflashed SD card should be able to boot the existing SSD rootfs without destroying it.

## Proposed behaviour

Introduce a "detect and reattach" path in `root_dir_migrate` (or a new sibling role) with roughly this shape:

1. Discover the SSD LV as today.
2. Mount the LV read-only at `/mnt/new_root` for inspection.
3. If `/mnt/new_root/sbin/init` (or equivalent) exists **and** `/mnt/new_root/etc/fstab` already has a valid root entry pointing at the LV UUID: treat the LV as a live rootfs. Skip the rsync.
4. Either way, update the SD card's `cmdline.txt` so `root=UUID=<lv-uuid>` points at the LV, ensure the SD's initramfs has LVM support (`update-initramfs -u` after installing `lvm2` + `initramfs-tools`), unmount, reboot.
5. Post-reboot assertion is the same as today: `findmnt /` returns the LV.

If the LV has no valid rootfs (first provision, or LV was wiped) fall through to the current rsync-based bootstrap.

## Open questions

- How strict should the "valid rootfs" check be? `/sbin/init` presence is the minimum; comparing OS release, kernel modules, or a marker file written by a prior successful run would be safer.
- Should the reattach path also refuse to run if the SSD rootfs is *older* than the SD image (avoids booting into a stale OS)? If so, what's the signal?
- Do we want an explicit "force rebuild" tag on the playbook (e.g. `--tags rebuild-root`) so the current destructive behaviour is still reachable when a rebuild is actually desired?
- Same question applies to the potato nodes (`boot_mount` role): confirm they benefit from the same fix or document why they don't.

## Non-goals

- Automatic SD card flashing. Reflash stays a manual laptop-based step.
- Restoring node-local state that lives outside the root LV (there shouldn't be any).

## Current recovery procedures

Two paths exist today. Path A is what today's roles support; Path B is what this ticket aims to enable.

### Path A — full wipe (SD + SSD)

Use when the SSD's rootfs is compromised, when the node's Longhorn replicas have already been rebuilt elsewhere, or when you simply want a clean slate. Followed for lib-pi-02 on 2026-08-22 after the watchdog-induced boot failure.

1. Evict workloads from the node first:
   ```
   kubectl delete node <node>
   ```
   Force-delete any pods stuck in `Terminating` and clear stale `VolumeAttachment` objects so Longhorn can reattach volumes elsewhere. Wait until every affected volume shows a healthy replica count on the remaining nodes before proceeding.
2. Reflash the SD card with a fresh Pi OS image.
3. Boot the node, SSH in.
4. **Wipe the SSD before running Ansible.** Identify the ~1TB SSD, then clear it:
   ```
   lsblk -bdno NAME,SIZE,TYPE | awk '$3=="disk"'
   sudo wipefs -a /dev/sdX
   sudo dd if=/dev/zero of=/dev/sdX bs=1M count=100
   ```
   `wipefs` clears partition/LVM signatures; the `dd` guarantees nothing auto-detects stale metadata.
5. Run the playbook. `root_storage` and `longhorn_disk_setup` treat the disk as fresh; `root_dir_migrate` does the full rsync.
    * run common
    * run k3s nodes and node_labels
    * run longhorn
    * run observability node_exporter
    * run watchdog

6. After k3s joins: confirm `kubectl get nodes` shows the node Ready with the expected labels, and confirm the Longhorn UI lists the node's disk as `Schedulable` with no orphaned replicas.

#### Gotcha — stale Longhorn disk record after wipe

`kubectl delete node <node>` removes the k8s `Node` object but **not** the `nodes.longhorn.io` CR of the same name. The Longhorn CR persists across the reflash and still references the *old* disk UUID. When `longhorn_disk_setup` creates a fresh filesystem, the disk's `.longhorn-disk.cfg` gets a new UUID; Longhorn compares and refuses to mark the disk `Ready`, reporting `DiskFilesystemChanged` and `record diskUUID doesn't match the one on the disk`. Node view in the UI shows the disk as detached / not ready.

Fix: remove the stale disk entry so Longhorn re-registers the fresh one.

- UI: Node → `<node>` → Edit Node and Disks → set the stale disk's scheduling to Disable → Save → reopen and delete the disk → Save.
- kubectl: `kubectl edit -n longhorn-system nodes.longhorn.io <node>` and delete the whole `default-disk-<hash>:` block under `spec.disks`.
- kubectl (if a webhook rejects the edit): `kubectl patch -n longhorn-system nodes.longhorn.io <node> --type=json -p='[{"op":"remove","path":"/spec/disks/default-disk-<hash>"}]'`

The `node.longhorn.io/create-default-disk: "true"` label (applied by the longhorn playbook) makes Longhorn auto-register the fresh disk within seconds. Confirm with the `diskStatus.*.conditions` on the node CR — you want `Ready: True` and `Schedulable: True` on a new `default-disk-<different-hash>`.

### Path B — SD reflash, preserve SSD rootfs (what this ticket enables)

Use when only the SD card has failed and the SSD rootfs is intact and worth keeping (avoids the full reprovision cost, keeps any local state that isn't yet Ansibled).

Not currently supported — the unconditional rsync in `root_dir_migrate` will overwrite the SSD rootfs. Delivering the reattach path in `issues/01-detect-and-reattach-existing-rootfs.md` will make this flow work as:

1. Reflash the SD card.
2. Boot, SSH in, run the playbook.
3. `root_dir_migrate` detects a valid rootfs on the LV, skips the rsync, rewrites the SD's `cmdline.txt` + initramfs, reboots onto the existing SSD rootfs.
