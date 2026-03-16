# Node OS Update Runbook

## Overview

This runbook covers two scenarios:
1. **Routine update** — `apt upgrade` within the current Debian major version
2. **Major version upgrade** — `dist-upgrade` to a new Debian release (e.g. Bullseye → Bookworm)

For cluster nodes, always cordon and drain before starting. Never touch more than one 
node at a time. lib-pi-06 is not a cluster node — skip cordon/drain for that one.

---

## Pre-flight Checks

Before touching any node:

```bash
# Check cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed

# Confirm node you're about to update
kubectl describe node <node-name> | grep -E "Taints|Conditions"
```

Only proceed if the cluster is healthy and no pods are in a bad state.

---

## Routine Update (within current Debian version)

### Step 1 — Cordon and drain (cluster nodes only)
```bash
kubectl cordon <node-name>
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

Wait for drain to complete. Verify:
```bash
kubectl get pods -A -o wide | grep <node-name>
# Should return nothing (or only daemonset pods)
```

### Step 2 — Run the update playbook
```bash
ansible-playbook playbooks/os_update.yaml -e "target=<node-name>"
```

This will:
- Run `apt update && apt full-upgrade`
- Reboot the node
- Wait for it to come back online

### Step 3 — Verify node rejoined
```bash
kubectl get nodes
# Node should show Ready within a minute or two of reboot
```

k3s rejoins the cluster automatically — no manual intervention needed.

### Step 4 — Uncordon
```bash
kubectl uncordon <node-name>
```

### Step 5 — Verify workloads reschedule
```bash
kubectl get pods -A -o wide | grep <node-name>
```

---

## Major Version Upgrade (dist-upgrade)

> ⚠️ Do this on one node at a time. Validate fully before moving to the next.
> Check the Raspberry Pi OS release notes before upgrading — there may be 
> Pi-specific packages that need attention.

### Step 1 — Cordon and drain (cluster nodes only)
Same as routine update above.

### Step 2 — SSH into the node
```bash
ssh-keygen -R <node-ip>  # clear old host key if needed
ssh <node-ip>
```

### Step 3 — Update current packages first
```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

SSH back in after reboot.

### Step 4 — Update sources.list to new release
```bash
# Check current release
cat /etc/os-release

# Update to new release (adjust version names as appropriate)
# Example: Bullseye -> Bookworm
sudo sed -i 's/bullseye/bookworm/g' /etc/apt/sources.list
sudo sed -i 's/bullseye/bookworm/g' /etc/apt/sources.list.d/*.list

# Verify the changes look correct before proceeding
cat /etc/apt/sources.list
```

### Step 5 — Run dist-upgrade
```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

This will take longer than a routine update. The node will reboot automatically 
via the playbook or manually if done by hand.

### Step 6 — Verify upgrade succeeded
```bash
cat /etc/os-release
# Should show new Debian version

# Check k3s is running
sudo systemctl status k3s
# or on worker nodes
sudo systemctl status k3s-agent
```

### Step 7 — Verify node rejoined and uncordon
```bash
kubectl get nodes
kubectl uncordon <node-name>
```

---

## Master Node (lib-potato-02) — Special Considerations

> ⚠️ The control plane will be unavailable while the master is down. Workers will 
> continue running existing workloads but no scheduling changes can be made.

Additional steps for the master:

```bash
# Before starting - note the current cluster state
kubectl get nodes
kubectl get pods -A

# No cordon/drain needed for the master itself
# Just proceed with the update

# After reboot - verify control plane is back
kubectl get nodes
kubectl cluster-info
```

If the master fails to come back:
1. SSH in and check k3s service: `sudo systemctl status k3s`
2. Check logs: `sudo journalctl -u k3s -n 100`
3. If k3s won't start, run the k3s Ansible playbook against the master:
   ```bash
   ansible-playbook playbook.yaml --limit lib-potato-02
   ```

---

## lib-pi-06 (External Node)

Not a cluster node — no cordon/drain needed.

```bash
# SSH in
ssh lib-pi-06

# Run update
sudo apt update && sudo apt full-upgrade -y
sudo reboot

# After reboot, verify services
sudo systemctl status prometheus
sudo docker ps  # verify any docker services are back
```

---

## Troubleshooting

**Node stuck in NotReady after reboot:**
```bash
# Check k3s agent on the node
sudo systemctl status k3s-agent
sudo journalctl -u k3s-agent -n 50

# Usually just needs a moment - wait 2-3 minutes before investigating
```

**SSH connection refused after reboot:**
```bash
# Clear stale host key
ssh-keygen -R <node-ip>
# Wait a minute and retry - node may still be booting
```

**Drain stuck waiting for pods:**
```bash
# If a pod is refusing to evict
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force
```

**apt upgrade prompts for config file decisions:**  
Generally accept the package maintainer's version (`Y`) unless you know you have 
custom config in that file. For k3s related config, keep your version.
