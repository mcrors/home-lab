# Handoff — 2026-09-06 — Blackbox probe discovery

## Project

Home lab Kubernetes cluster (`mcrors/home-lab`), alerting stack. Tickets live in `docs/alerting/`,
numbered `01`–`12`. `README.md` in that directory is the operational reference; `alerts-to-create.md`
is the alert backlog.

## What this session did

Replaced the hand-maintained blackbox probe list with Kubernetes service discovery, so an ingress
opts into monitoring with an annotation rather than an edit to `prometheus.yml.j2`.

Ticket 10 (`10-blackbox-ingress-autodiscovery.md`) is closed.

| Commit | Change |
|---|---|
| `8680dc9` | `prometheus-scraper` ClusterRole granted `list`/`watch` on `networking.k8s.io/ingresses` |
| `4a86c7f` | `blackbox-ingress` scrape job added, using `kubernetes_sd_configs` with `role: ingress` |
| `28956f8` | plex annotated (with a `probe-path` override) and migrated off the `node_type` label |
| `ae179a4` | prowlarr, radarr, sonarr, transmission, uptime-kuma annotated |
| `0aa6f70` | alertmanager, blackbox, grafana, kube-state-metrics, ntfy annotated |
| `5d16386` | longhorn annotated |
| `9eb6f85` | static `blackbox-http` list shrunk from 12 targets to 3 |
| `ded143a` | `BlackboxIngressDiscoveryEmpty` and `BlackboxStaticTargetsEmpty` guards added |

### Where probe coverage landed

| Job | Targets | Source |
|---|---|---|
| `blackbox-ingress` | 12 | Every cluster ingress carrying `prometheus.io/probe: "true"` |
| `blackbox-http` | 3 | `prometheus`, `omv`, `traefik`, none of which has an Ingress |

`alertmanager.houli.eu`, `ntfy.houli.eu` and `uptime.houli.eu` were previously probed by nothing, so
a failure in the notification path itself was invisible.

### Things that cost time, worth not rediscovering

- The namespace label from ingress discovery is `__meta_kubernetes_namespace`. It does **not** carry
  the `ingress` infix that `__meta_kubernetes_ingress_host`, `_path`, `_scheme` and `_name` all do.
- `count(x) == 0` cannot detect an empty target list. `count()` over an empty vector returns an
  empty vector, so the comparison never evaluates. Use `absent(x)`.
- `--limit localhost` matches nothing, because Ansible will not target an implicit localhost that is
  not in the inventory. To run only the localhost half of a tagged pair of plays, add a tag.
- Every `--tags prometheus` run restarts Prometheus. The role ends in
  `docker-compose up --force-recreate -d`, which is a `command` and therefore never idempotent.
- `prometheus_sd_discovered_targets{config="<job>"}` counts what discovery returned before
  relabelling. It is the only way to tell "discovery found nothing" from "discovery worked and the
  filter dropped everything", since both show zero active targets.

## Open work, roughly in priority order

### 1. `NodeRecentlyRebooted` cannot fire

`infra/roles/prometheus/files/alerts.yaml:90` selects `up{job=~"node-exporter|node"}`. The job is
named `node_exporter` with an underscore, and Prometheus anchors regex matchers fully, so the rule
has never matched anything.

This is a one-character fix that unblocks the whole reboot-visibility thread: ticket 08, plus
`NodeUnexpectedReboot` and `MultiNodeRebootWindow` in the backlog. Reboot visibility matters here
because the watchdog reboots nodes and, until `armbian-ramlog` was disabled, the reboot destroyed
the evidence of its own cause.

### 2. The 2026-08-27 coverage gap

`PodNotReady` and `DeploymentReplicaMismatch` in `alerts-to-create.md`. On 2026-08-27,
metallb-controller, cert-manager-webhook, alertmanager and signal-bridge all sat at 0/1 with no
alert firing. Blackbox probing does not close this: three of those four have no HTTP surface, so no
probe can see them. The two mechanisms cover different failures and both are needed.

### 3. Two alerts that are deployed but cannot fire

- `TraefikHighErrorRate` queries `traefik_service_requests_total`; there is no Traefik scrape job.
- `DNSResolutionFailed` selects `job="blackbox-dns"`; no such job exists.

Each needs a scrape job adding or the rule removing. Leaving them in place is worse than either,
because the rules page looks healthy while two alerts are permanently dead.

### 4. Tickets 11 and 12

`11-alert-grouping-and-inhibition.md` is now unblocked: probe alerts carry a `namespace` label, so
they can be joined against kube-state-metrics alerts in an inhibit rule. Note the deployed route has
no `group_by`, so every alert currently lands in one aggregation group.

`12-dead-mans-switch.md` is the largest remaining hole. ntfy and signal-bridge both run in-cluster,
so a cluster-wide failure takes out the alerting path silently. The decision recorded there and not
yet made is whether to accept an outbound third-party dependency to get a canary that survives total
cluster loss.

### 5. Grafana dashboards, tickets 08 and 09

Neither started. `infra/roles/grafana/files/values.yaml` has `dashboardProviders` and `dashboards`
commented out, so dashboards are not reproducible from code today. Worth deciding on provisioning
before hand-building panels.

## Environment notes

- Prometheus is **external**: Docker Compose on lib-pi-06, not a cluster workload. Config at
  `/mnt/prometheus/config/`, rules at `/mnt/prometheus/config/rules/alerts.yml`.
- Committed does not mean deployed. The prometheus role is run by hand and the repo drifted four
  months from lib-pi-06 before 2026-09-05. Verify against the host, not the repo.
- Ansible lives in a virtualenv at `~/venvs/ansible/`. Run `infra/` playbooks from `infra/` and
  `services/` playbooks from `services/`, since both `ansible.cfg` files use relative paths.
- The k3s API server is reachable at the `master_ip` VIP, `192.168.1.249:6443`, defined in
  `infra/vars/main.yaml`.
- `infra/playbooks/longhorn.yaml` has no tags, and its first play runs `longhorn_disk_setup` against
  the storage nodes. Do not run it to push a small change; the longhorn ingress annotation was
  applied with `kubectl annotate` for this reason.
