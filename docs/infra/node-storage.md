# Node Storage

## Overview

This project covers all storage related work across the cluster nodes and external nodes.
This includes physical SSD installation, Longhorn reconfiguration, and moving volatile 
directories off SD cards onto SSDs for improved reliability and longevity.

### Node Inventory

| Node | Type | Role | Storage |
|------|------|------|---------|
| lib-pi-01 | Pi4 4GB | k3s worker | 1TB SSD (Longhorn) |
| lib-pi-02 | Pi4 4GB | k3s worker | 1TB SSD (Longhorn) |
| lib-pi-03 | Pi4 4GB | k3s worker | 1TB SSD (Longhorn) |
| lib-pi-04 | Pi4 4GB | k3s worker (reclaimed from PiHole) | 1TB SSD (Longhorn) |
| lib-pi-05 | Pi5 8GB | k3s worker | 1TB SSD (Longhorn) |
| lib-potato-01 | La Potato 2GB | k3s worker | 128GB SSD (system) |
| lib-potato-02 | La Potato 2GB | k3s master | 128GB SSD (system) |
| lib-potato-03 | La Potato 2GB | k3s worker | 128GB SSD (system) |
| lib-potato-04 | La Potato 2GB | k3s worker | 128GB SSD (system) |
| lib-pi-06 | Pi4 4GB | external (Prometheus) | 1TB SSD (Prometheus), 500GB SSD (iSCSI → repurposed) |

---

## Tasks

---

### STORAGE-01 — Buy and install SSDs

**Type:** Hardware  
**Priority:** High  
**Blocked by:** Nothing

**Description:**  
Purchase and physically install SSDs across all nodes. Pi nodes (lib-pi-01 to 05) already 
have 1TB SSDs for Longhorn — these will be reconfigured in STORAGE-05 to also serve as 
system volumes. La Potatoes and the master need dedicated 128GB SSDs for system use.

**Shopping list:**
- 4x 128GB SSD + USB enclosure — lib-potato-01 to 04
- 1x 128GB SSD + USB enclosure — lib-potato-02 (master)
- USB hub for shelf mounting (optional but recommended for cable tidiness)

> Note: lib-pi-06 already has two SSDs. The 500GB iSCSI SSD will be repurposed for 
> system use once iSCSI is migrated to Longhorn.

**Acceptance Criteria:**
- All SSDs physically connected via USB 3.0
- SSDs visible on each node via `lsblk`
- Nodes remain stable after physical installation

---

### STORAGE-02 — Disable swap across all nodes

**Type:** Configuration  
**Priority:** High  
**Blocked by:** STORAGE-01

**Description:**  
k3s requires swap to be disabled. Raspberry Pi OS enables swap by default via 
`dphys-swapfile`. This should be added to the `common` or `k3s_prereq` Ansible role 
so it applies to all nodes.

**Verify current state:**
```bash
free -h
swapon --show
```

**Manual steps (if needed):**
```bash
sudo swapoff -a
sudo systemctl disable dphys-swapfile
sudo systemctl stop dphys-swapfile
sudo dphys-swapfile swapoff
sudo dphys-swapfile uninstall
```

**Ansible task to add to `k3s_prereq` role:**
```yaml
- name: Disable swap immediately
  command: swapoff -a

- name: Disable dphys-swapfile service
  systemd:
    name: dphys-swapfile
    state: stopped
    enabled: false

- name: Remove swapfile
  command: dphys-swapfile uninstall
  ignore_errors: yes
```

**Acceptance Criteria:**
- `free -h` shows 0 swap on all nodes
- `swapon --show` returns empty on all nodes
- Change is persistent across reboots
- Added to Ansible role so future nodes get this automatically

---

### STORAGE-03 — Verify and fix systemd journal persistence

**Type:** Configuration  
**Priority:** Medium  
**Blocked by:** Nothing

**Description:**  
By default Debian does not persist the systemd journal across reboots — logs are lost 
on restart which makes post-reboot debugging very difficult. At least one node has 
already had this fixed after an unexpected reboot incident. This task ensures it is 
consistent across all nodes and added to the `common` role.

**Verify current state:**
```bash
ls /var/log/journal
# If directory exists, journal is persistent
# If not, logs are lost on reboot
```

**Manual steps (if needed):**
```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
```

**Ansible task to add to `common` role:**
```yaml
- name: Ensure journal directory exists for persistence
  file:
    path: /var/log/journal
    state: directory
    owner: root
    group: systemd-journal
    mode: '2755'

- name: Restart journald to pick up persistence
  systemd:
    name: systemd-journald
    state: restarted
```

> Note: Once /var/log is moved to SSD in STORAGE-06, journal persistence is automatically
> maintained on the SSD. This task ensures it is correct in the interim.

**Acceptance Criteria:**
- `/var/log/journal` exists on all nodes
- Journal survives a reboot — verify with `journalctl --list-boots`
- Added to `common` Ansible role

---

### STORAGE-04 — Mount /tmp as tmpfs

**Type:** Configuration  
**Priority:** Low  
**Blocked by:** Nothing

**Description:**  
Mounting `/tmp` as tmpfs moves temporary file writes to RAM rather than the SD card, 
reducing SD card wear. `/tmp` contents are ephemeral by definition so there is no 
downside to losing them on reboot. Note: do NOT mount `/var/tmp` as tmpfs — that 
directory is expected to survive reboots.

**Verify current state:**
```bash
mount | grep tmp
```

**Ansible task to add to `common` role:**
```yaml
- name: Mount /tmp as tmpfs
  mount:
    path: /tmp
    src: tmpfs
    fstype: tmpfs
    opts: defaults,noatime,mode=1777,size=256m
    state: mounted
```

**Acceptance Criteria:**
- `mount | grep tmp` shows tmpfs on `/tmp` on all nodes
- `/var/tmp` remains on normal filesystem
- Change is persistent across reboots
- Added to `common` Ansible role

---

### STORAGE-05 — Reconfigure Longhorn disk allocation (90/10 split)

**Type:** Infrastructure  
**Priority:** High  
**Blocked by:** STORAGE-01

**Description:**  
Currently the Longhorn playbook gives 100% of the SSD to the Longhorn VG. This needs 
to be reconfigured to a 90/10 split — 90% for Longhorn, 10% for a system VG that will 
host `/var/lib/rancher` and `/var/log` (see STORAGE-06). Since nothing is currently on 
Longhorn this is a clean teardown and reinstall.

**Applies to:** lib-pi-01, lib-pi-02, lib-pi-03, lib-pi-04, lib-pi-05

**Step 1 — Uninstall Longhorn via Helm:**
```bash
helm uninstall longhorn -n longhorn-system
```

**Step 2 — Clean up LVM on each Pi node:**
```bash
# Unmount
sudo umount /var/lib/longhorn

# Remove fstab entry
sudo sed -i '/longhorn/d' /etc/fstab

# Remove LV
sudo lvremove /dev/longhorn-vg/longhorn-lv

# Remove VG
sudo vgremove longhorn-vg

# Remove PV (replace sdX with actual device)
sudo pvremove /dev/sdX
```

**Step 3 — Update Longhorn playbook:**  
Update the LV creation task to use 90% instead of 100%:
```yaml
# Before
- name: Create logical volume (new VG)
  lvol:
    vg: longhorn-vg
    lv: longhorn-lv
    size: 100%FREE
  when: node_type == 'pi' and lv_check.rc != 0

# After
- name: Create logical volume (new VG)
  lvol:
    vg: longhorn-vg
    lv: longhorn-lv
    size: 90%FREE
  when: node_type == 'pi' and lv_check.rc != 0
```

**Step 4 — Reinstall Longhorn via playbook:**
```bash
ansible-playbook playbook.yaml --tags longhorn
```

**Acceptance Criteria:**
- Longhorn reinstalled and healthy
- Longhorn VG uses 90% of SSD on each Pi node
- 10% free space available in VG for system LV (created in STORAGE-06)
- Longhorn UI shows all nodes healthy

---

### STORAGE-06 — Move /var/lib/rancher and /var/log to SSD

**Type:** Infrastructure  
**Priority:** High  
**Blocked by:** STORAGE-01, STORAGE-05

**Description:**  
Move the two highest write directories off the SD card and onto the SSD. This dramatically 
reduces SD card wear and improves I/O performance for k3s. 

**For Pi nodes (lib-pi-01 to 05):** Create a new LV from the 10% free space left after 
the Longhorn reconfiguration in STORAGE-05.

**For Potato nodes (lib-potato-01 to 04):** Use the full 128GB SSD — create a VG and LV 
for system use.

**For lib-potato-02 (master):** Same as Potato nodes but the critical path is 
`/var/lib/rancher/k3s` which contains the SQLite database.

**LVM setup for Potato nodes (Ansible tasks):**
```yaml
- name: Create PV on system SSD
  command: pvcreate /dev/sdX

- name: Create system VG
  lvg:
    vg: system-vg
    pvs: /dev/sdX

- name: Create system LV
  lvol:
    vg: system-vg
    lv: system-lv
    size: 100%FREE
```

**Mount and migrate (all nodes):**
```bash
# Format
sudo mkfs.ext4 /dev/system-vg/system-lv

# Mount temporarily
sudo mount /dev/system-vg/system-lv /mnt/ssd

# Copy existing data
sudo rsync -av /var/lib/rancher /mnt/ssd/
sudo rsync -av /var/log /mnt/ssd/

# Add to fstab
echo '/dev/system-vg/system-lv /mnt/ssd ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab

# Bind mount
echo '/mnt/ssd/rancher /var/lib/rancher none bind 0 0' | sudo tee -a /etc/fstab
echo '/mnt/ssd/log /var/log none bind 0 0' | sudo tee -a /etc/fstab
```

> Note: This should be done with the node cordoned and drained, and ideally offline 
> to avoid bind mount ordering issues on reboot.

**Acceptance Criteria:**
- `df -h` shows `/var/lib/rancher` and `/var/log` mounted on SSD on all nodes
- k3s rejoins cluster cleanly after reboot
- SD card write activity effectively zero during normal operation
- Changes captured in Ansible `common` or `k3s_prereq` role for future nodes

---

## Summary

| Task | Type | Blocked by |
|------|------|------------|
| STORAGE-01 | Buy and install SSDs | — |
| STORAGE-02 | Disable swap | STORAGE-01 |
| STORAGE-03 | Fix journal persistence | — |
| STORAGE-04 | Mount /tmp as tmpfs | — |
| STORAGE-05 | Reconfigure Longhorn 90/10 | STORAGE-01 |
| STORAGE-06 | Move /var to SSD | STORAGE-01, STORAGE-05 |
