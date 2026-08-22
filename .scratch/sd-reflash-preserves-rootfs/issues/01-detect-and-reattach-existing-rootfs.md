Status: needs-triage

# Add "detect and reattach" path to root_dir_migrate

## Context

See `../spec.md` for background. This ticket is the first (and possibly only) implementation step: teach `infra/roles/root_dir_migrate` to preserve an existing SSD rootfs rather than always rsyncing over it.

## Scope

Modify `infra/roles/root_dir_migrate/tasks/main.yaml` so that after mounting `{{ lv_device }}` at `/mnt/new_root`, it branches on whether the LV already contains a bootable rootfs:

- **Reattach path** (LV has `/sbin/init` and a valid fstab root entry): skip rsync + fstab rewrite. Still update `{{ boot_cmdline_path }}` on the SD card to point `root=` at the LV UUID, ensure `lvm2` + `initramfs-tools` are installed and `update-initramfs -u` has run so the SD initramfs can activate the LV, unmount, reboot.
- **Bootstrap path** (LV is empty or lacks init): run today's rsync + fstab + cmdline flow unchanged.

Post-reboot assertion (`findmnt /` returns the LV) stays as-is and covers both paths.

## Acceptance criteria

- On a node whose SSD LV already holds a valid rootfs, running the playbook after an SD reflash reboots the node onto the SSD without re-rsyncing.
- On a node where the SSD LV is empty (first provision), behaviour is unchanged.
- Existing pi nodes that already have `root_already_on_ssd == true` short-circuit as they do today.
- Playbook is idempotent: a second run after successful reattach is a no-op.

## Test plan

- Dry-run against lib-pi-02 post-recovery once it's back in the cluster.
- Deliberately reflash a spare SD (or use a VM) and confirm reattach preserves the rootfs.
- Run against a node with no SSD LV to confirm the bootstrap path still works.

## Out of scope

- Any changes to `boot_mount` for potato nodes — track separately if the same fix applies.
- A `--tags force-rebuild-root` escape hatch — nice to have, defer unless the reattach path is hard to bypass.
