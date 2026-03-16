# Node Ops

## Overview

This project covers operational procedures for maintaining cluster nodes — specifically 
OS updates and upgrades. The goal is a documented, repeatable process that can be followed 
safely without having to reference chat history or figure it out from scratch each time.

**Key principle:** Always cordon and drain before touching a node. Never update more than 
one node at a time.

---

## Tasks

---

### OPS-01 — Create OS update runbook and playbook

**Type:** Development / Documentation  
**Priority:** High  
**Blocked by:** Nothing

**Description:**  
Create two things:
1. A runbook (`node-os-update-runbook.md`) documenting the full procedure for both 
   routine updates and major version upgrades — the document you open at 11pm when 
   something needs doing
2. An Ansible playbook (`playbooks/os_update.yaml`) for the actual update steps

The playbook handles the OS update only. Cordon and drain are manual steps done before 
running the playbook — this is intentional to prevent accidentally draining multiple 
nodes at once.

**Ansible playbook (`playbooks/os_update.yaml`):**
```yaml
---
- name: OS update
  hosts: "{{ target }}"
  become: true
  tasks:
    - name: apt update and full-upgrade
      apt:
        update_cache: yes
        upgrade: full

    - name: Reboot
      reboot:
        reboot_timeout: 300

    - name: Wait for node to come back
      wait_for_connection:
        delay: 10
        timeout: 300
```

**Run with:**
```bash
ansible-playbook playbooks/os_update.yaml -e "target=lib-pi-01"
```

**Acceptance Criteria:**
- `node-os-update-runbook.md` created at `home-lab/docs/infra/node-os-update-runbook.md`
- `playbooks/os_update.yaml` created and tested
- Runbook covers both routine updates and major version (dist-upgrade) procedure
- Runbook references the playbook

---

### OPS-02 — Test in-place OS upgrade on lib-pi-04

**Type:** Testing  
**Priority:** High  
**Blocked by:** OPS-01

**Description:**  
lib-pi-04 is being reclaimed from PiHole duty and will be re-added to the cluster anyway, 
making it the ideal test node for the in-place OS upgrade process. If something goes wrong 
a fresh OS install was planned regardless — zero risk.

Follow the runbook from OPS-01 for the full procedure. Key things to validate:

- k3s rejoins the cluster automatically after reboot
- No Ansible re-run needed for an in-place upgrade
- SSH host key handling (clear old key before reconnecting)
- Journal, swap, tmpfs all still correct after upgrade

**Steps:**
```bash
# 1. Cordon and drain
kubectl cordon lib-pi-04
kubectl drain lib-pi-04 --ignore-daemonsets --delete-emptydir-data

# 2. Clear old SSH host key
ssh-keygen -R <lib-pi-04-ip>

# 3. Run the update playbook
ansible-playbook playbooks/os_update.yaml -e "target=lib-pi-04"

# 4. Verify node rejoined
kubectl get nodes

# 5. Uncordon
kubectl uncordon lib-pi-04
```

**Acceptance Criteria:**
- Node completes upgrade without errors
- k3s rejoins cluster automatically — no manual intervention needed
- `kubectl get nodes` shows lib-pi-04 Ready
- Runbook updated with any findings or gotchas discovered during the test

---

### OPS-03 — Roll out in-place OS upgrade to remaining nodes

**Type:** Ops  
**Priority:** Low  
**Blocked by:** OPS-02

**Description:**  
Once the process is validated on lib-pi-04, roll out the OS upgrade to all remaining 
nodes one at a time following the runbook. Do not rush this — there is no urgency and 
the cluster is overprovisioned enough to handle nodes being temporarily unavailable.

**Node order (suggested):**
1. lib-potato-01 (worker, lowest impact)
2. lib-potato-03
3. lib-potato-04
4. lib-pi-01
5. lib-pi-02
6. lib-pi-03
7. lib-pi-05
8. lib-potato-02 (master — do this last, see note below)
9. lib-pi-06 (external node, not in cluster)

> ⚠️ **lib-potato-02 (master):** The control plane will be unavailable during the 
> upgrade. Ensure no critical operations are running. The cluster workers will continue 
> running existing workloads but no scheduling changes can be made until the master 
> comes back. Have the recovery runbook to hand.

> **lib-pi-06:** Not a cluster node so no cordon/drain needed. Just SSH in, run the 
> upgrade, reboot, verify Prometheus and any other services come back cleanly.

**Acceptance Criteria:**
- All nodes upgraded and showing Ready in `kubectl get nodes`
- No workload disruption reported
- Runbook updated with any per-node gotchas

---

## Summary

| Task | Type | Blocked by |
|------|------|------------|
| OPS-01 | Create runbook and playbook | — |
| OPS-02 | Test upgrade on lib-pi-04 | OPS-01 |
| OPS-03 | Roll out to remaining nodes | OPS-02 |
