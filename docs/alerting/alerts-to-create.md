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

Deployed to lib-pi-06 on 2026-09-06 as the `networking` rule group.

- [X] **BlackboxProbeFailed** — endpoint not responding to synthetic check (`probe_success == 0`).
- [X] **SSLCertExpiringSoon** — certificate expiring within 14d (warning) / 7d (critical).
- [~] **TraefikHighErrorRate** — deployed but **cannot fire**: no Traefik scrape job exists, so
      `traefik_service_requests_total` is never collected.
- [~] **DNSResolutionFailed** — deployed but **cannot fire**: the rule selects `job="blackbox-dns"`
      and the only blackbox jobs are `blackbox`, `blackbox-http` and `blackbox-ingress`.

### Probe coverage

Complete as of 2026-09-06. `blackbox-ingress` discovers targets from Ingress objects carrying
`prometheus.io/probe: "true"`; see the README for the annotation reference.

- [X] Ingress service discovery job live, verified against 12 discovered ingresses
- [X] All 12 cluster ingresses annotated and probing green. `alertmanager.houli.eu`,
      `ntfy.houli.eu` and `uptime.houli.eu` were previously probed by nothing.
- [X] `plex` carries a `probe-path` override for `/web/index.html`, since it answers 401 at `/`
- [X] `blackbox-http` shrunk to the three out-of-cluster targets: `prometheus`, `omv`, `traefik`
- [X] Empty-target guards added: `BlackboxIngressDiscoveryEmpty` and `BlackboxStaticTargetsEmpty`.
      Both use `absent()`. `count(...) == 0` cannot work here: `count()` over an empty vector
      returns an empty vector, so the comparison never evaluates.
- [ ] Decide whether the two blackbox jobs should carry the `cluster` label added in `ea4c481`

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

- [X] Add `inhibit_rules` — critical suppresses warning for same alertname + instance. Deployed and
      verified in `configmap/alertmanager`.
- [ ] Set `group_by` on the route. Currently unset, so every alert lands in a single aggregation
      group and unrelated alerts batch into one notification. See `11-alert-grouping-and-inhibition.md`.

## Broken rule

- [ ] **NodeRecentlyRebooted** never fires. `alerts.yaml:90` selects `up{job=~"node-exporter|node"}`
      but the job is named `node_exporter`. Prometheus anchors regex matchers fully, so this matches
      nothing. Blocks reboot visibility, which `08-node-reboot-panel.md`, `NodeUnexpectedReboot` and
      `MultiNodeRebootWindow` all depend on.
