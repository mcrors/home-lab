# Homepage Dashboard — Project Plan

## Overview

Deploy [Homepage](https://gethomepage.dev) as a self-hosted landing page for the homelab cluster.
The primary goal is a visually polished, always-on dashboard showing live cluster state and
links to all services. Managed via a custom Helm chart and Ansible role, consistent with the
existing repo pattern.

**Repo paths affected:**
- `services/helm/homepage/` — new custom Helm chart
- `services/roles/homepage/` — new Ansible role
- `services/playbooks/homepage.yaml` — new playbook
- `services/playbook.yaml` — import the new playbook here
- Existing service `values.yaml` files — add `gethomepage.dev/*` Ingress annotations

---

## Design Decisions

| Concern | Decision |
|---------|----------|
| Helm chart | Custom chart (`services/helm/homepage/`) — no well-maintained community chart exists |
| Config strategy | Static `ConfigMap` for settings/widgets/off-cluster bookmarks; in-cluster services via Ingress annotation discovery |
| Persistence | None — all config lives in the ConfigMap; stateless deployment |
| Scheduling | `nodeSelector: node_type: pi` — hard selector is fine for this workload |
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
- `ClusterRole` — read access to `namespaces`, `pods`, `nodes`, `ingresses`, `metrics.k8s.io/nodes`, `metrics.k8s.io/pods`
- `ClusterRoleBinding`
- `ConfigMap` — keys: `settings.yaml`, `services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `kubernetes.yaml`, `custom.css`
- `Deployment` — single replica, `nodeSelector: node_type: pi`, `HOMEPAGE_ALLOWED_HOSTS` env var
- `Service` — ClusterIP, port 3000
- `Ingress` — Traefik, `websecure`, wildcard TLS via cluster TLSStore

**Acceptance Criteria:**
- `helm lint` passes cleanly
- `helm template` renders all resources without error
- `nodeSelector` correctly targets Pi nodes
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
- `services/roles/homepage/files/values.yaml`
- `services/playbooks/homepage.yaml`
- Update `services/playbook.yaml` to import the new playbook

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

All services use this annotation set:
```yaml
gethomepage.dev/enabled: "true"
gethomepage.dev/name: "<display name>"
gethomepage.dev/description: "<short description>"
gethomepage.dev/group: "<Infra|Media|CI/Ops>"
gethomepage.dev/icon: "<icon-name.png>"
gethomepage.dev/href: "https://<service>.houli.eu"
```

**Service checklist:**

| Service | Group | Icon | Notes |
|---------|-------|------|-------|
| Plex | Media | `plex.png` | |
| Sonarr | Media | `sonarr.png` | |
| Radarr | Media | `radarr.png` | |
| Prowlarr | Media | `prowlarr.png` | |
| Transmission | Media | `transmission.png` | |
| Pi-hole | Infra | `pi-hole.png` | |
| Longhorn | Infra | `longhorn.png` | |
| Blackbox Exporter | Infra | `prometheus.png` | |
| Uptime Kuma | CI/Ops | `uptime-kuma.png` | |
| Grafana | CI/Ops | `grafana.png` | |
| Jenkins | CI/Ops | `jenkins.png` | Add annotation when Ingress is live |
| Traefik dashboard | Infra | `traefik.png` | Add annotation when Ingress is live |

**Acceptance Criteria:**
- All annotated services appear on the Homepage dashboard under the correct group
- Icons resolve correctly from the built-in Walkxcode pack
- No services appear in the wrong group

---

### HOM-05 — Add service widgets for live data

**Type:** Enhancement
**Blocked by:** HOM-04
**Priority:** Low — purely cosmetic, do after everything else is stable

**Description:**
Homepage supports per-service API widgets that pull live stats directly into the
service card (e.g. Sonarr queue count, Pi-hole query rate, Grafana status).
Add widgets for services that support them via additional annotations or `services.yaml` entries.

**Candidates:**
- Pi-hole: query rate, blocked percentage
- Sonarr: queue / missing episodes
- Radarr: queue / missing films
- Prowlarr: indexer count
- Transmission: active torrents

**Acceptance Criteria:**
- At least Pi-hole and one *arr widget showing live data
- No widget errors in Homepage logs

---

## Summary

| Task | Type | Blocked by | Notes |
|------|------|------------|-------|
| HOM-01 | Helm chart scaffold | — | |
| HOM-02 | ConfigMap content | HOM-01 | |
| HOM-03 | Ansible role + playbook | HOM-01 | |
| HOM-04 | Ingress annotations — all services | HOM-03 | Jenkins + Traefik deferred to when Ingress exists |
| HOM-05 | Per-service live widgets | HOM-04 | Low priority / cosmetic |
