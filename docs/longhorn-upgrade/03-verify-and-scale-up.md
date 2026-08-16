# Task: Verify Longhorn Health and Scale Workloads Back Up

After the upgrade, confirm Longhorn is healthy and bring all workloads back up.

## Steps

**1. Confirm instance-manager is running on all storage nodes**

```bash
kubectl get pods -n longhorn-system | grep instance-manager
# Expect one pod per storage node: lib-nuc-01, lib-pi-01, lib-pi-02, lib-pi-03, lib-pi-05
```

**2. Scale workloads back up**

```bash
kubectl scale deploy -n plex plex --replicas=1
kubectl scale deploy -n grafana grafana --replicas=1
kubectl scale deploy -n prowlarr prowlarr --replicas=1
kubectl scale deploy -n sonarr sonarr --replicas=1
kubectl scale deploy -n radarr radarr --replicas=1
kubectl scale deploy -n uptime-kuma uptime-kuma --replicas=1
```

**3. Watch pods come up**

```bash
kubectl get pods -n plex -n grafana -n prowlarr -n sonarr -n radarr -n uptime-kuma -w
```

**4. Confirm volumes reattach healthy**

```bash
kubectl get volumes.longhorn.io -n longhorn-system
# STATE: attached, ROBUSTNESS: healthy for all six
```

## Known issue: multipathd conflict

After an instance-manager restart or upgrade, `multipathd` can claim the newly-created iSCSI
block devices, causing pods to get stuck in `ContainerCreating` with `FailedMount` events.

**Symptoms:** kernel logs show `Can't open blockdev`; `fsck` reports device "is in use".

**Check:**
```bash
ssh lib-nuc-01 sudo multipath -ll
```

**Fix:** flush any multipath devices that have claimed Longhorn iSCSI disks:
```bash
ssh lib-nuc-01 sudo multipath -f mpatha
ssh lib-nuc-01 sudo multipath -f mpathb   # if present
```

These devices are never mounted on a filesystem — flushing them is safe.

See task 04 for the permanent fix.

## Validation

- All 6 pods Running with 0 restarts
- All 6 volumes attached and healthy in Longhorn
- Check lib-nuc-01 memory — instance-manager should be ~50MB, not growing

```bash
ssh lib-nuc-01 "ps aux --sort=-%mem | grep instance-manager | grep -v grep | awk '{print \$6/1024 \"MB\", \$11}'"
```

## Dependencies

- Task 02 (upgrade) must be complete.
