# Homepage Dashboard — Project Plan

## Overview

Deploy [Homepage](https://gethomepage.dev) as a self-hosted landing page for the homelab cluster.
The primary goal is a visually polished, always-on dashboard showing live cluster state and
links to all services. Managed via a custom Helm chart and Ansible role, consistent with the
existing repo pattern.

**Repo paths affected:**
- `services/helm/homepage/` — new custom Helm chart
- `services/roles/homepage/` — new Ansible role
- `services/playbook.yaml` — add a play here; `services/` has no `playbooks/` directory, every play is inline in this one file
- Existing service `values.yaml` files — add `gethomepage.dev/*` Ingress annotations

---

## Design Decisions

| Concern | Decision |
|---------|----------|
| Helm chart | Custom chart (`services/helm/homepage/`) — no well-maintained community chart exists |
| Config strategy | Static `ConfigMap` for settings/widgets/off-cluster bookmarks; in-cluster services via Ingress annotation discovery |
| Persistence | None — all config lives in the ConfigMap; stateless deployment |
| Scheduling | `nodeAffinity` on `node_size In ["medium"]`. No `nodeSelector`: in this repo that key is reserved for `longhorn-storage`, and Homepage is stateless |
| RBAC | `ClusterRole` with read access to Ingresses, Nodes, Pods, and metrics API |
| Custom CSS | IBM Plex Mono terminal aesthetic matching the mockup — delivered via `custom.css` key in ConfigMap |
| Service discovery | `gethomepage.dev/*` annotations on each service's Ingress, set via `values.yaml` |

---

## Service Grouping

| Group | Services |
|-------|----------|
| **Infra** | Longhorn, Pi-hole, Blackbox Exporter, Traefik |
| **Media** | Plex, Sonarr, Radarr, Prowlarr, Transmission |
| **CI/Ops** | Jenkins, Grafana, Uptime Kuma |

---

## Off-Cluster Bookmarks (static config)

These have no k8s Ingress and are defined directly in `services.yaml` / `bookmarks.yaml`:

- NAS (OMV — Radxa Penta HAT Pi)
- `lib-pi-06` — Prometheus, Garage S3
- Postgres data node

---

## Tasks

---

### HOM-01 — Scaffold the Helm chart

**Type:** Development
**Blocked by:** Nothing

**Description:**
Create the custom Helm chart under `services/helm/homepage/` following the existing
Prowlarr chart as the reference pattern.

**Resources required:**
- `ServiceAccount`
- `ClusterRole` — read access to `namespaces`, `pods`, `nodes`, `ingresses`, `traefik.io/ingressroutes`, `metrics.k8s.io/nodes`, `metrics.k8s.io/pods`
- `ClusterRoleBinding`
- `ConfigMap` — keys: `settings.yaml`, `services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `kubernetes.yaml`, `custom.css`, `custom.js`. Mounted per file with `subPath`, never as a directory over `/app/config`, which homepage writes logs into
- `Deployment` — single replica, `affinity` (see Scheduling above), `HOMEPAGE_ALLOWED_HOSTS` env var
- `Service` — ClusterIP, port 3000
- `Ingress` — Traefik, `websecure`, wildcard TLS via cluster TLSStore

**Acceptance Criteria:**
- `helm lint` passes cleanly
- `helm template` renders all resources without error
- `affinity` renders and targets `node_size` `medium`
- ConfigMap contains all required keys

---

### HOM-02 — Implement ConfigMap content

**Type:** Development
**Blocked by:** HOM-01

**Description:**
Populate the ConfigMap keys with real config for the cluster.

**`kubernetes.yaml`:**
```yaml
mode: cluster
```

**`widgets.yaml`:**
- Kubernetes cluster widget (CPU, memory, nodes)
- Kubernetes nodes widget (per-node CPU and memory)
- Search bar (DuckDuckGo)

**`settings.yaml`:**
- Title: `houli.eu`
- Dark theme
- `HOMEPAGE_ALLOWED_HOSTS`: `homepage.houli.eu`

**`services.yaml`:**
Off-cluster entries only:
- NAS admin UI
- lib-pi-06: Prometheus, Garage
- Postgres node

**`bookmarks.yaml`:**
- GitHub repo link
- Any other static bookmarks

**`custom.css`:**
Terminal aesthetic matching the mockup:
- Font: IBM Plex Mono
- Background: `#0d0f11` with subtle grid overlay
- Accent: `#3b82f6` (blue), `#22d3ee` (cyan)
- Card borders, muted labels, monospace data values

**Acceptance Criteria:**
- All keys render valid YAML
- Off-cluster services appear in their own group
- Custom CSS loads without errors in browser

---

### HOM-03 — Create Ansible role and playbook

**Type:** Development
**Blocked by:** HOM-01

**Description:**
Wire up the Ansible role following the standard pattern:
create namespace → create secrets (none needed here) → `helm upgrade --install`.

**Files:**
- `services/roles/homepage/tasks/main.yaml`
- `services/roles/homepage/defaults/main.yaml`
- `services/roles/homepage/files/values.yaml`
- Append a `homepage` play to `services/playbook.yaml`, following the `uptime-kuma` play at the end of that file

**`values.yaml` should set at minimum:**
- `ingress.hosts[0]`: `homepage.houli.eu`
- `ingress.tls`: reference to `houli-eu-wildcard`
- `env.HOMEPAGE_ALLOWED_HOSTS`: `homepage.houli.eu`

**Acceptance Criteria:**
- Playbook runs idempotently
- Pod reaches `Running` state
- `homepage.houli.eu` resolves and loads in browser
- Cluster widget shows live node CPU/memory data

---

### HOM-04 — Add Ingress annotations to existing services

**Type:** Configuration
**Blocked by:** HOM-03 (deploy first so discovery can be validated live)

**Description:**
Add `gethomepage.dev/*` annotations to the Ingress in each service's `values.yaml`.
For community charts this means the Helm values ingress annotations block.
For custom charts this means the chart's `values.yaml` passed in by the Ansible role.

Four services already carry these annotations, added during the alerting work:
`infra/roles/alertmanager/files/values.yaml`, `infra/roles/kube_state_metrics/tasks/main.yaml`,
`infra/roles/ntfy/tasks/main.yaml`, and `infra/roles/k3s_config/tasks/main.yaml` (Traefik).
Follow the form they established rather than the one originally drafted here:

```yaml
gethomepage.dev/enabled: "true"
gethomepage.dev/name: "<display name>"
gethomepage.dev/group: "<Infra|Media|CI/Ops>"
gethomepage.dev/icon: "<icon-name>"
gethomepage.dev/description: "<short description>"
```

Two differences from the original draft: the icon name carries no `.png` extension, and there is
no `href` — Homepage derives the link from the Ingress host. Keep new annotations consistent with
the four that exist.

**Service checklist:**

| Service | Group | Icon | Notes |
|---------|-------|------|-------|
| Plex | Media | `plex` | |
| Sonarr | Media | `sonarr` | |
| Radarr | Media | `radarr` | |
| Prowlarr | Media | `prowlarr` | |
| Transmission | Media | `transmission` | |
| Longhorn | Infra | `longhorn` | |
| Blackbox Exporter | Infra | `prometheus` | |
| Uptime Kuma | CI/Ops | `uptime-kuma` | |
| Grafana | CI/Ops | `grafana` | |
| Alertmanager | Infra | `alertmanager` | Already annotated |
| kube-state-metrics | Infra | `prometheus` | Already annotated |
| Ntfy | Infra | `ntfy` | Already annotated |
| Traefik dashboard | Infra | `traefik` | Already annotated, on an `IngressRoute` CRD. Discovered only when `kubernetes.yaml` sets `traefik: true`, and only if `gethomepage.dev/href` is added — the one service that needs that annotation |
| Jenkins | CI/Ops | `jenkins` | Deferred — `.scratch/jenkins/issues/07-monitoring-and-homepage.md` owns this row |
| Pi-hole | Infra | `pi-hole` | Not in the cluster yet; add when that project lands |

**Acceptance Criteria:**
- All annotated services appear on the Homepage dashboard under the correct group
- Icons resolve correctly from the built-in Walkxcode pack
- No services appear in the wrong group

---

### HOM-06 — Audit and fix every service icon

**Type:** Development
**Blocked by:** HOM-04

**Description:**
The icon names in the HOM-04 checklist are guesses at what the icon pack calls each service, and a
missing icon degrades to a text placeholder rather than an error. Open the live dashboard, check
every card including the four annotated before any dashboard existed, and fix what is wrong. Use an
`mdi-<name>` Material Design icon where the pack has nothing. Correct the HOM-04 checklist to match
whatever ends up deployed.

**Acceptance Criteria:**
- Every card renders a real icon; no text placeholders or broken images
- kube-state-metrics and Blackbox Exporter do not share one generic Prometheus icon
- Changed names are corrected in both the owning role and this document

---

### HOM-05 — Add service widgets for live data

**Type:** Enhancement
**Blocked by:** HOM-06
**Priority:** Undecided — revisit once the dashboard is stable and see whether it is worth doing

**Description:**
Homepage supports per-service API widgets that pull live stats directly into the
service card (e.g. Sonarr queue count, Transmission active torrents).
Each widget needs an API key, which must not go in an annotation; see
`.scratch/homepage/issues/05-service-widgets.md` for the cost that decision carries.

**Candidates:**
- Sonarr: queue / missing episodes
- Radarr: queue / missing films
- Prowlarr: indexer count
- Transmission: active torrents

**Acceptance Criteria:**
- At least one *arr widget showing live data
- No API key readable from any annotation
- No widget errors in Homepage logs

---

## Summary

| Task | Type | Blocked by | Notes |
|------|------|------------|-------|
| HOM-01 | Helm chart scaffold | — | |
| HOM-02 | ConfigMap content | HOM-01 | |
| HOM-03 | Ansible role + playbook | HOM-01 | |
| HOM-04 | Ingress annotations — all services | HOM-03 | Jenkins deferred to the Jenkins effort; Pi-hole is not in the cluster yet |
| HOM-06 | Icon audit | HOM-04 | Last step before the dashboard is done |
| HOM-05 | Per-service live widgets | HOM-06 | Undecided; may not be done at all |
