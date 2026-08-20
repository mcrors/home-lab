# Task: Investigate Grafana Volume Instability

Status: MONITORING — no issues since v1.11.2 upgrade (2026-08-18). Close if clean after 2026-08-25.

The Grafana PVC (`pvc-22d72383`, 1Gi) had its engine die unexpectedly 6 times over the
31 days prior to the upgrade. The most likely cause was memory pressure on lib-nuc-01 from
the Longhorn proxy connection leak bug (fixed in v1.11.2). Volume has been attached and
healthy with no errors for 72h post-upgrade. Continuing to monitor.

The Grafana PVC (`pvc-22d72383`, 1Gi) has had its engine die unexpectedly 6 times over the
last 31 days, independently of the instance-manager memory issue. This needs investigation
to rule out a flaky replica, a bad disk, or a networking issue between the engine and its
replicas.

## Observed symptoms

```
Warning  DetachedUnexpectedly  x6 over 31d  longhorn-volume-controller
Engine of volume pvc-22d72383-223d-495a-9cd2-0934538df359 dead unexpectedly,
setting v.Status.Robustness to faulted
```

The volume self-healed each time (Longhorn reattached it), but 6 unexpected engine deaths in
31 days is not normal and warrants investigation before the upgrade.

## Replica placement

As of Aug 2026, the Grafana volume has 2 replicas:

- `pvc-22d72383-r-48a5ecc1` — lib-nuc-01
- `pvc-22d72383-r-a049ee80` — lib-pi-05

## Investigation steps

**1. Check Longhorn volume event history**

```bash
kubectl describe volume.longhorn.io pvc-22d72383-223d-495a-9cd2-0934538df359 -n longhorn-system
```

Look for patterns in the fault timestamps — same time of day, correlated with other events?

**2. Check replica health on both nodes**

```bash
kubectl get replicas.longhorn.io -n longhorn-system -l longhornvolume=pvc-22d72383-223d-495a-9cd2-0934538df359
```

**3. Check disk health on lib-nuc-01**

```bash
ssh lib-nuc-01 sudo smartctl -a /dev/sda   # or whichever disk hosts longhorn-storage
ssh lib-nuc-01 sudo dmesg | grep -i 'error\|ata\|scsi\|disk' | tail -30
```

**4. Check disk health on lib-pi-05**

```bash
ssh lib-pi-05 sudo dmesg | grep -i 'error\|ata\|scsi\|disk' | tail -30
```

**5. Check instance-manager logs on lib-nuc-01 around fault times**

Pull timestamps from the volume events, then:

```bash
kubectl logs -n longhorn-system <instance-manager-pod> --since=<duration> | grep -i '22d72383\|error\|fault\|dead'
```

**6. Check network stability between engine (lib-nuc-01) and pi-05 replica**

The engine on lib-nuc-01 connects to the replica on lib-pi-05 over TCP. Engine death can be
caused by replica timeouts if there's packet loss or latency spikes between nodes.

```bash
ssh lib-nuc-01 ping -c 100 192.168.1.238   # lib-pi-05
```

## Possible outcomes

| Finding | Action |
|---------|--------|
| Disk errors on lib-nuc-01 or lib-pi-05 | Replace disk, rebuild replica on healthy node |
| Network drops between nuc and pi-05 | Investigate switch/cable; move replica to pi-01/02 |
| Correlated with high memory pressure (pre-fix) | Monitor post-upgrade — may self-resolve |
| No clear cause | Add a recurring Longhorn snapshot job to reduce recovery time if it faults again |

## Dependencies

- Can be done independently of tasks 01–04, but ideally after the upgrade so the memory
  pressure on lib-nuc-01 is no longer a confounding factor.
