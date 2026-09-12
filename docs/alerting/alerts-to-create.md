# Alerting To-Do

## Update existing

- [X] **HighCPUUsage** — rename both tiers to same alertname, use severity label only to differentiate. Warning 90%/15m, critical 95%/5m.
- [X] **HostHardwareTemp** — rename both tiers to same alertname. Check SBC thermal labels in Prometheus (`node_hwmon_temp_celsius` vs `node_thermal_zone_temp`) and add parallel rules if pis/potatoes use different metrics.
- [X] **NodeDown** — remove from Prometheus, move to Uptime Kuma.

## New alerts — Kubernetes

- [X] **KubeNodeNotReady** — node in cluster but not in Ready state. Catches kubelet/network issues.
- [X] **PodCrashLooping** — pod restart count climbing. Something broken, k3s cycling it.
- [X] **PodStuckPending** — pod can't be scheduled. Resource exhaustion or affinity mismatch.
- [X] **PodNotReady** — pod in phase `Running` but ready condition false for >15m. Catches faults
      that no other rule sees: the pod is not crashlooping (phase stays `Running`), not pending,
      and the node stays `Ready`, so nothing else fires. This is the gap that let the 2026-08-27
      containerd name-reservation wedge run unnoticed for 6h on potato-04 and far longer on pi-01.
      Deployed 2026-09-12. A crashlooping pod is also Running and not ready, so `PodCrashLooping`
      inhibits this alert rather than the exclusion being buried in the expression.
- [X] **DeploymentReplicaMismatch** — available replicas < desired. Service degraded.
      Deployed 2026-09-12.
- [X] **StatefulSetReplicaMismatch** / **DaemonSetNotFullyAvailable** — the same check for the
      other two workload kinds. **The earlier note on this ticket was wrong**: it claimed a
      Deployment-only rule would have caught metallb-controller, cert-manager-webhook,
      alertmanager and signal-bridge on 2026-08-27. Alertmanager is a StatefulSet, so it would
      have been missed, and metallb also runs two DaemonSets carrying LoadBalancer traffic.
      kube-state-metrics exposes a separate metric family per workload kind, so covering all
      three takes three rules. Deployments alone cover 29 of 37 workloads.
      Note `kube_daemonset_status_desired_number_scheduled` counts only schedulable nodes, so a
      dead node lowers both sides and does not fire the DaemonSet rule; `KubeNodeNotReady`
      covers that case.
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
- [X] **NodeRebooted** — fires on any node with an uptime under 5m. Surfaces watchdog trips, which
      were previously invisible: the reboot wipes the zram `/var/log` before anything is persisted,
      so there is no post-hoc evidence of the cause. Deployed 2026-09-12.
- [X] **NodeUnexpectedReboot** — folded into `NodeRebooted` rather than built as a separate rule.
      The backlog wording assumed a maintenance-window mechanism that this repo does not have, and
      encoding one in PromQL duplicates what Alertmanager silences already do. Set a silence before
      a planned reboot; an unsilenced firing is the unexpected case. The cost of this choice is that
      silences are manual, so an Ansible run that reboots a node notifies unless you silence first.
- [X] **MultiNodeRebootWindow** — 2+ nodes rebooting within the same 10m window. A synchronised
      reboot means a shared upstream cause (gateway/network blip tripping the watchdog ping check),
      rather than independent hardware faults. Four nodes went down together at 15:00 on 2026-08-27.
      Deployed 2026-09-12 as `count by (cluster) (time() - node_boot_time_seconds{job="node_exporter"} < 600) >= 2`.
      It counts short-uptime nodes instead of using `changes(node_boot_time_seconds[10m]) > 0`,
      which needs samples from both sides of the reboot inside the window and so misses any node
      that stays down longer than the window.

## Dead man's switch

Built 2026-09-12 as the `dead_mans_switch` role on lib-pi-06. See `12-dead-mans-switch.md`.

- [X] **DeadMansSwitch** — daily all-is-well message through the real pipeline to Signal. Absence
      is the signal.
- [X] **SignalCliImageStale** — signal-cli image older than 60 days. Proactive by design: it fires
      while signal-cli still works, so the upgrade prompt reaches a channel that is not yet broken.
      A heartbeat cannot do this job, because a dead signal-cli reports itself only as silence.
- [X] **SignalCliTagUnreadable** / **SignalCliImageUnknown** — the staleness check has gone blind.
      A check that silently stops checking is worse than no check.
- [X] `ntfy-oneshot` receiver added, identical to `ntfy` but `send_resolved: false`, so one-shot
      alerts do not each send a second `[Resolved]` message.
- [ ] Off-site watchdog so absence detection is not a human job and something survives total
      cluster loss. Split out to `13-offsite-pipeline-watchdog.md`.

## Alertmanager config

- [X] Add `inhibit_rules` — critical suppresses warning for same alertname + instance. Deployed and
      verified in `configmap/alertmanager`.
- [X] Second inhibit rule — `MultiNodeRebootWindow` suppresses `NodeRebooted`, matched on `cluster`.
      Without it a synchronised reboot sends one notification per node on top of the aggregate. The
      first inhibit rule cannot do this job: it matches on `instance`, and an aggregate built with
      `count by (cluster)` carries no `instance` label. Deployed 2026-09-12.
- [X] Third inhibit rule — `PodCrashLooping` suppresses `PodNotReady`, matched on `namespace` and
      `pod`. Deployed 2026-09-12.
- [ ] Set `group_by` on the route. Currently unset, so every alert lands in a single aggregation
      group and unrelated alerts batch into one notification. See `11-alert-grouping-and-inhibition.md`.

## Fixed rule

- [X] **NodeRecentlyRebooted** never fired, and is now `NodeRebooted`. The rule selected
      `up{job=~"node-exporter|node"}` while the job is named `node_exporter`, and Prometheus anchors
      regex matchers fully, so the left side of the multiplication was always an empty vector.
      Confirmed before the fix by running both selectors with the threshold raised to ten years:
      `job="node_exporter"` matched all 12 nodes, `job=~"node-exporter|node"` matched nothing.
      Fixed and deployed 2026-09-12.
