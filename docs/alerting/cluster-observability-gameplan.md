# Cluster Observability Stack — Game Plan

## Current State

- **Prometheus**: external, on lib-pi-06
- **Grafana**: in-cluster, exposed via Traefik at `grafana.houli.eu`
- **kube-state-metrics**: not installed
- **kubelet/cAdvisor scraping**: not configured
- **Alertmanager**: not installed
- **Notification system**: none

---

## Phase 1: Metrics Collection

### 1.1 — kube-state-metrics  - DONE

**Goal**: Kubernetes object state metrics (pod phase, node conditions, deployment replicas, etc.)

- [X] Deploy via Helm into `monitoring` namespace
- [X] Expose via Traefik IngressRoute at `ksm.houli.eu` (or similar)
  - TLS via existing `houli-eu-wildcard` cert
  - Consider: restrict access via Traefik middleware (IP allowlist to lib-pi-06 and local network)
- [X] Add scrape job to `prometheus.yml` on lib-pi-06:
  ```yaml
  - job_name: 'kube-state-metrics'
    scheme: https
    tls_config:
      insecure_skip_verify: true  # if using self-signed wildcard
    static_configs:
      - targets: ['ksm.houli.eu:443']
  ```
- [X] Validate: `curl -s https://ksm.houli.eu/metrics | head` returns metrics
- [X] Validate: Prometheus targets page shows kube-state-metrics as UP

**Key metrics unlocked**: `kube_node_status_condition`, `kube_pod_status_phase`, `kube_pod_deletion_timestamp`, `kube_pod_container_status_waiting_reason`, `kube_deployment_status_replicas`, `kube_persistentvolumeclaim_status_phase`, etc.

### 1.2 — Kubelet / cAdvisor Metrics - DONE

**Goal**: actual container resource consumption (CPU, memory, network, filesystem)

The kubelet (embedded in the k3s agent process) exposes cAdvisor metrics at `:10250/metrics/cadvisor`. These are already there — no additional software to install.

- [X] Verify kubelet is running: `ps aux | grep k3s` (not `grep kubelet` — k3s bundles it)
- [X] Verify the metrics endpoint responds from a node:
  ```bash
  # From inside a pod with the right service account:
  curl -k https://localhost:10250/metrics/cadvisor \
    -H "Authorization: Bearer <token>"
  ```
- [X] Create RBAC for Prometheus scraping:
  - ServiceAccount `prometheus-scraper` in `monitoring` namespace
  - ClusterRole with rules:
    - `apiGroups: [""]`, `resources: ["nodes/metrics", "nodes/proxy"]`, `verbs: ["get"]`
  - ClusterRoleBinding binding the above
  - Create a long-lived token (Secret of type `kubernetes.io/service-account-token`) or use `kubectl create token` with `--duration`
- [X] Add scrape job to `prometheus.yml` on lib-pi-06:
  ```yaml
  - job_name: 'kubelet-cadvisor'
    scheme: https
    tls_config:
      insecure_skip_verify: true
    bearer_token: '<extracted-token>'
    metrics_path: /metrics/cadvisor
    static_configs:
      - targets:
          - '<lib-pi-01>:10250'
          - '<lib-pi-02>:10250'
          - '<lib-pi-03>:10250'
          - '<lib-pi-04>:10250'
          - '<lib-pi-05>:10250'
          - '<lib-potato-01>:10250'
          - '<lib-potato-02>:10250'
          - '<nuc-ip>:10250'
  ```
- [X] Validate: Prometheus targets page shows all nodes as UP for `kubelet-cadvisor` job
- [X] Validate: query `container_cpu_usage_seconds_total` in Prometheus returns data

**Key metrics unlocked**: `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, `container_network_receive_bytes_total`, `container_network_transmit_bytes_total`, `container_fs_usage_bytes`, etc.

**Note**: The `/var/run/secrets/kubernetes.io/serviceaccount/token` path only exists inside pods. You cannot use it from the host. The RBAC + extracted token approach above is the correct path for an external Prometheus.

---

## Phase 2: Alerting

### 2.1 — Alertmanager

**Goal**: receive firing alerts from Prometheus, route to notification channels.

- [X] Deploy Alertmanager in-cluster via Helm (`monitoring` namespace)
- [X] Expose via Traefik IngressRoute at `alertmanager.houli.eu`
  - TLS via wildcard cert
  - IP allowlist middleware (lib-pi-06 + local network)
- [X] Configure Prometheus on lib-pi-06 to send alerts to Alertmanager:
  ```yaml
  alerting:
    alertmanagers:
      - scheme: https
        tls_config:
          insecure_skip_verify: true
        static_configs:
          - targets: ['alertmanager.houli.eu:443']
  ```
- [ ] Configure Alertmanager to route to Ntfy (Phase 3) via webhook receiver
- [X] Validate: Prometheus status page shows Alertmanager as connected

### 2.2 — Alert Rules

**Goal**: define what fires.

Rules live in Prometheus on lib-pi-06 as `rule_files`. Define and refine once metrics from Phase 1 are flowing.

Candidate rules (non-exhaustive — expand once data is visible):

| Alert | Source | Expression (approx) |
|-------|--------|---------------------|
| Node not ready | kube-state-metrics | `kube_node_status_condition{condition="Ready",status="true"} == 0` for 5m |
| Pod stuck terminating | kube-state-metrics | `kube_pod_deletion_timestamp > 0` and age > 15m |
| Pod CrashLoopBackOff | kube-state-metrics | `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0` for 5m |
| PVC pending | kube-state-metrics | `kube_persistentvolumeclaim_status_phase{phase="Pending"} == 1` for 10m |
| High memory usage | kubelet/cAdvisor | `container_memory_working_set_bytes / kube_pod_container_resource_limits{resource="memory"} > 0.9` for 10m |
| Longhorn volume degraded | Longhorn metrics | `longhorn_volume_robustness == 2` for 5m (if Longhorn metrics are scraped) |

- [ ] Create `alert_rules.yml` on lib-pi-06
- [ ] Reference in `prometheus.yml` under `rule_files`
- [ ] Validate: Prometheus rules page shows rules loaded and evaluating

---

## Phase 3: Notifications

### 3.1 — Ntfy

**Goal**: self-hosted push notifications to iPhone, no inbound network exposure.

**How it works**:
1. Ntfy server runs in-cluster
2. Alertmanager pushes to Ntfy over the LAN (webhook)
3. Ntfy server pushes notification to `ntfy.sh` upstream relay (outbound HTTPS)
4. `ntfy.sh` relay pushes to Apple APNs
5. iPhone receives push notification

No inbound connections to your network at any point. Notification content (topic + message body) does transit through ntfy.sh infrastructure — acceptable for homelab alerts.

- [ ] Deploy Ntfy in-cluster via Helm or static manifests (`monitoring` namespace)
  - Persistent storage for message cache (Longhorn PVC)
  - Config: enable upstream relay (`upstream-base-url: https://ntfy.sh`)
- [ ] Expose via Traefik IngressRoute at `ntfy.houli.eu`
  - TLS via wildcard cert
  - This one needs to be reachable from the LAN (phone on WiFi for web UI), not just lib-pi-06
- [ ] Install Ntfy iOS app, subscribe to your alert topic(s)
- [ ] Configure Alertmanager webhook receiver:
  ```yaml
  receivers:
    - name: 'ntfy'
      webhook_configs:
        - url: 'http://ntfy.monitoring.svc.cluster.local/homelab-alerts'
          send_resolved: true
  ```
- [ ] Configure Uptime Kuma to push to Ntfy:
  - Notification type: Ntfy
  - Server URL: `http://ntfy.monitoring.svc.cluster.local` (if Uptime Kuma is in-cluster) or `https://ntfy.houli.eu` (if external)
  - Topic: `homelab-alerts` (or a separate topic like `uptime-alerts`)
- [ ] Validate: `curl -d "test alert" https://ntfy.houli.eu/homelab-alerts` → notification on phone
- [ ] Future: self-hosted APNs relay in the cloud to remove ntfy.sh dependency

---

## Phase 4: Grafana Dashboards

### 4.1 — Cluster Overview Dashboard

**Goal**: high-level view of cluster health — node status, pod counts, resource allocation vs capacity.

- [ ] Import or build a dashboard querying kube-state-metrics data:
  - Node readiness status
  - Total pods running / pending / failed by namespace
  - Deployment replica status (desired vs available)
  - PVC status
  - Resource requests vs allocatable (CPU, memory) per node
- [ ] Standard community dashboards to evaluate: IDs 13770, 315 on grafana.com (may need adaptation for external Prometheus)

**Requires**: Phase 1.1 (kube-state-metrics) complete

### 4.2 — Pod Resource Drill-Down Dashboard

**Goal**: per-pod CPU/memory/network usage with namespace and pod filtering.

- [ ] Import or build a dashboard querying cAdvisor metrics:
  - CPU usage over time per pod (from `container_cpu_usage_seconds_total`)
  - Memory working set per pod (from `container_memory_working_set_bytes`)
  - Network I/O per pod
  - Filesystem usage per pod
  - Namespace dropdown, pod dropdown filters
- [ ] Standard community dashboards to evaluate: IDs 15760, 17375 on grafana.com

**Requires**: Phase 1.2 (kubelet/cAdvisor scraping) complete

### 4.3 — Longhorn Dashboard (bonus)

- [ ] If not already present, scrape Longhorn manager metrics and add a volume health dashboard
- [ ] Longhorn exposes metrics at `longhorn-backend.longhorn-system.svc:9500/metrics`
  - Needs a scrape job on lib-pi-06 (same pattern: expose via ingress or NodePort)

---

## Dependency Graph

```
Phase 1.1 (kube-state-metrics) ──┬──→ Phase 2.2 (alert rules)
                                 ├──→ Phase 4.1 (cluster dashboard)
                                 │
Phase 1.2 (kubelet/cAdvisor) ────┼──→ Phase 2.2 (alert rules)
                                 ├──→ Phase 4.2 (pod resource dashboard)
                                 │
Phase 2.1 (Alertmanager) ────────┤
                                 │
Phase 3.1 (Ntfy) ────────────────┘──→ Phase 2.1 routes to Phase 3.1
```

Phases 1.1 and 1.2 can proceed in parallel.
Phase 2.1 (Alertmanager) and Phase 3.1 (Ntfy) can proceed in parallel.
Phase 2.2 (alert rules) depends on all of 1.1, 1.2, 2.1, and 3.1.
Phase 4.x depends on the corresponding Phase 1.x.

---

## Open Decisions

| Item | Options | Notes |
|------|---------|-------|
| Ntfy auth | None / token-based / user+pass | For LAN-only, none is simplest. Add auth if you want to prevent anyone on your network from publishing. |
| Alert topic separation | Single `homelab-alerts` / split by severity or source | Single is simpler to start; split later if noise becomes an issue. |
| Longhorn metrics scraping | Via ingress / NodePort / not yet | Low priority but completes the picture. |
| kube-state-metrics ingress path | `ksm.houli.eu` / `metrics.houli.eu/ksm` | Subdomain is cleaner given your existing pattern. |
| Uptime Kuma location | In-cluster / external | Affects how it reaches Ntfy. |
