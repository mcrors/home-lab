# Alerting To-Do

## Update existing

- [X] **HighCPUUsage** — rename both tiers to same alertname, use severity label only to differentiate. Warning 90%/15m, critical 95%/5m.
- [X] **HostHardwareTemp** — rename both tiers to same alertname. Check SBC thermal labels in Prometheus (`node_hwmon_temp_celsius` vs `node_thermal_zone_temp`) and add parallel rules if pis/potatoes use different metrics.
- [X] **NodeDown** — remove from Prometheus, move to Uptime Kuma.

## New alerts — Kubernetes

- [X] **KubeNodeNotReady** — node in cluster but not in Ready state. Catches kubelet/network issues.
- [X] **PodCrashLooping** — pod restart count climbing. Something broken, k3s cycling it.
- [X] **PodStuckPending** — pod can't be scheduled. Resource exhaustion or affinity mismatch.
- [ ] **PodNotReady** — pod in phase `Running` but ready condition false for >15m. Catches faults
      that no other rule sees: the pod is not crashlooping (phase stays `Running`), not pending,
      and the node stays `Ready`, so nothing else fires. This is the gap that let the 2026-08-27
      containerd name-reservation wedge run unnoticed for 6h on potato-04 and far longer on pi-01.
- [ ] **DeploymentReplicaMismatch** — available replicas < desired. Service degraded.
      Raised priority: on 2026-08-27 this would have caught metallb-controller, cert-manager-webhook,
      alertmanager and signal-bridge all sitting at 0/1 with no alert firing.
- [X] **ContainerOOMKilled** — container hit memory limit. Needs limit tuning.
- [ ] **JobFailed** — CronJob or Job exited non-zero. Silent batch failures.

## New alerts — Storage (Longhorn)

- [X] **LonghornVolumeDegraded** — replica count below configured (2). One failure from data loss.
- [X] **LonghornVolumeFaulted** — volume inaccessible. Active incident.
- [X] **LonghornDiskSpaceLow** — Longhorn storage node running low (separate from OS-level disk).

## New alerts — Networking / Ingress

- [ ] **BlackboxProbeFailed** — endpoint not responding to synthetic check (`probe_success == 0`).
- [ ] **SSLCertExpiringSoon** — certificate expiring within 14d (warning) / 7d (critical). Catches cert-manager failures.
- [ ] **TraefikHighErrorRate** — elevated 5xx rate across ingress.
- [ ] **DNSResolutionFailed** — blackbox DNS probe failing. Pi-hole is single point of failure.

## New alerts — Observability meta

- [ ] **PrometheusTargetDown** — any scrape target unreachable. "Is my monitoring actually monitoring."
- [ ] **PrometheusStorageFilling** — TSDB disk on pi-06 growing toward capacity.

## New alerts — Node health

- [ ] **SystemClockSkew** — node time drifted from NTP (`node_timex_offset_seconds`). Breaks TLS, cron, log correlation.
- [ ] **NodeUnexpectedReboot** — `node_boot_time_seconds` changed without a planned maintenance
      window. Surfaces watchdog trips, which are currently invisible: the reboot wipes the zram
      `/var/log` before anything is persisted, so there is no post-hoc evidence of the cause.
- [ ] **MultiNodeRebootWindow** — 2+ nodes rebooting within the same 10m window. A synchronised
      reboot means a shared upstream cause (gateway/network blip tripping the watchdog ping check),
      not independent hardware faults. Four nodes went down together at 15:00 on 2026-08-27.

## Alertmanager config

- [ ] Add `inhibit_rules` — critical suppresses warning for same alertname + instance.
