# Task: Scale Down Longhorn-Dependent Workloads

Status: DONE

Scale all workloads that hold Longhorn PVCs to zero replicas before any Longhorn changes.
Restarting the instance-manager takes all volumes offline simultaneously — scaling down first
means a clean, intentional detach rather than a hard drop mid-operation.

## Why this is necessary

The Longhorn instance-manager manages all volume engines on a node. When it restarts (or is
upgraded), every engine process it owns is killed, and all attached volumes go dark at the same
time. Pods that are running when this happens see their filesystems vanish mid-operation and can
be left in a bad state (e.g. SQLite WAL not flushed, Plex database mid-write).

Scaling to zero first lets the kubelet unmount the volumes cleanly before anything is restarted.

## Workloads to scale down

All seven consume Longhorn PVCs and are scheduled on lib-nuc-01 or lib-pi-05:

| Workload | Namespace | PVC | Size |
|----------|-----------|-----|------|
| Plex | plex | pvc-plex | 12Gi |
| Grafana | grafana | pvc-grafana | 1Gi |
| Prowlarr | prowlarr | pvc-prowlarr | 1Gi |
| Sonarr | sonarr | pvc-sonarr | 5Gi |
| Radarr | radarr | pvc-radarr | 5Gi |
| Uptime Kuma | uptime-kuma | uptime-kuma-pvc | 2Gi |
| Ntfy | ntfy | pvc-ntfy | 2Gi |

## Steps

```bash
kubectl scale deploy -n plex plex --replicas=0
kubectl scale deploy -n grafana grafana --replicas=0
kubectl scale deploy -n prowlarr prowlarr --replicas=0
kubectl scale deploy -n sonarr sonarr --replicas=0
kubectl scale deploy -n radarr radarr --replicas=0
kubectl scale deploy -n uptime-kuma uptime-kuma --replicas=0
kubectl scale deploy -n ntfy ntfy --replicas=0
```

Confirm all pods are gone before proceeding:

```bash
kubectl get pods -n plex -n grafana -n prowlarr -n sonarr -n radarr -n uptime-kuma -n ntfy
```

Confirm all Longhorn volumes are detached:

```bash
kubectl get volumes.longhorn.io -n longhorn-system
# STATE column should show "detached" for all six
```

## Dependencies

None — this is the first step and gates everything else.
