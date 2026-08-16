# Longhorn Runbook

## Before any Longhorn changes (instance-manager restart, upgrade, etc.)

**Scale all workloads to 0 replicas before touching Longhorn.**

Restarting the instance-manager takes all 6 volumes offline simultaneously. Pods that are running when this happens will see their filesystems vanish mid-operation. Scaling down first means a clean, intentional detach rather than a hard drop.

Workloads with Longhorn PVCs (as of Aug 2026):

| Workload | Namespace | PVC |
|----------|-----------|-----|
| Plex | plex | pvc-plex (12Gi) |
| Grafana | grafana | pvc-grafana (1Gi) |
| Prowlarr | prowlarr | pvc-prowlarr (1Gi) |
| Sonarr | sonarr | pvc-sonarr (5Gi) |
| Radarr | radarr | pvc-radarr (5Gi) |
| Uptime Kuma | uptime-kuma | uptime-kuma-pvc (2Gi) |

Scale down:
```bash
kubectl scale deploy -n plex plex --replicas=0
kubectl scale deploy -n grafana grafana --replicas=0
kubectl scale deploy -n prowlarr prowlarr --replicas=0
kubectl scale deploy -n sonarr sonarr --replicas=0
kubectl scale deploy -n radarr radarr --replicas=0
kubectl scale deploy -n uptime-kuma uptime-kuma --replicas=0
```

Scale back up (after Longhorn is healthy):
```bash
kubectl scale deploy -n plex plex --replicas=1
kubectl scale deploy -n grafana grafana --replicas=1
kubectl scale deploy -n prowlarr prowlarr --replicas=1
kubectl scale deploy -n sonarr sonarr --replicas=1
kubectl scale deploy -n radarr radarr --replicas=1
kubectl scale deploy -n uptime-kuma uptime-kuma --replicas=1
```

## Known issue: multipathd claiming iSCSI disks after instance-manager restart

After an instance-manager restart, `multipathd` can grab the newly-created iSCSI block
devices, causing CSI mount failures ("already mounted or mount point busy").

**Symptoms:** Pods stuck in `ContainerCreating` with repeated `FailedMount` events; kernel
logs show `Can't open blockdev` for the Longhorn device.

**Fix:**
```bash
# Check which multipath devices are holding Longhorn iSCSI disks
sudo multipath -ll

# Flush them (safe — they are never mounted on a filesystem, just claimed)
sudo multipath -f mpatha
sudo multipath -f mpathb   # if present
```

**Permanent fix:** Add an `/etc/multipath.conf` blacklist for `IET VIRTUAL-DISK` devices
so multipathd ignores Longhorn iSCSI sessions. (Not yet applied — tracked for the v1.11.2
upgrade.)
