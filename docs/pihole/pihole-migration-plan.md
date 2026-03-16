# PiHole Migration to K3s Cluster

## Overview

Migrate PiHole from a standalone Raspberry Pi 4 into the K3s cluster as a Helm chart,
improving resilience and unifying management under the existing infra stack.

**Repo structure affected:**
- `home-lab/infra/roles/pihole/` — new Ansible role to deploy the Helm chart
- `home-lab/infra/playbooks/pihole.yaml` — new playbook calling the role
- `home-lab/infra/playbook.yaml` — import the new playbook here
- `home-lab/docker-server/` — existing playbook to be deleted (see PIHOLE-08)

---

## Dependency

> ⚠️ **Longhorn must be set up before this project goes live.**
> PiHole will use a Longhorn PVC for gravity DB persistence and will serve as the
> first workload to validate Longhorn storage in the cluster.

---

## Tasks

---

### PIHOLE-01 — Allocate a dedicated MetalLB IP for PiHole

**Type:** Infrastructure
**Priority:** High
**Blocked by:** Nothing

**Description:**
Reserve a specific IP from the MetalLB pool exclusively for PiHole. This IP will be
the DNS address that the router points to and must remain stable permanently.

**Acceptance Criteria:**
- A specific IP is chosen and documented from the MetalLB range
- The IP is annotated/reserved so MetalLB does not assign it to any other service
- The chosen IP is recorded in the chart `values.yaml`

**Status:** Done

---

### PIHOLE-02 — Export current PiHole configuration

**Type:** Ops / Backup
**Priority:** High
**Blocked by:** Nothing

**Description:**
Before making any changes, export all configuration from the existing PiHole instance.
The custom DNS entries (all `*.houli.eu` records) are the most critical — these cannot
be reconstructed from a backup if lost.

**Acceptance Criteria:**
- Gravity DB exported and saved
- Blocklist sources documented
- All custom DNS entries exported and stored in the repo or a safe location
- Admin password noted securely

**Status:** Won't Do. Config will be handled in the playbook


---

### PIHOLE-03 — Create Ansible role, playbook, and Helm chart scaffold

**Type:** Development
**Priority:** Medium
**Blocked by:** PIHOLE-01

**Description:**
Scaffold the Ansible role and playbook following the existing pattern in the repo,
alongside the Helm chart. The role is responsible for deploying/upgrading the chart.
The Helm chart follows the same minimal parameterisation pattern used elsewhere —
values file used as documented variables rather than full template abstraction.

**Acceptance Criteria:**
- `home-lab/infra/roles/pihole/` created with tasks to `helm upgrade --install` the chart
- `home-lab/infra/playbooks/pihole.yaml` created, calling the role
- `home-lab/infra/playbook.yaml` updated to import the new playbook
- `home-lab/pihole/Chart.yaml` created with appropriate metadata
- `home-lab/pihole/values.yaml` created containing at minimum: MetalLB IP, image tag, storage size,
  admin password reference, replica count, resource limits
- `home-lab/piholetemplates/` directory scaffolded
- Chart lints cleanly with `helm lint`

**Status:** Done. Using community helm chart instead

---

### PIHOLE-04 — Implement Kubernetes resources in the chart

**Type:** Development
**Priority:** Medium
**Blocked by:** PIHOLE-03, Longhorn

**Description:**
Implement all required Kubernetes resource templates within the Helm chart.

**Resources required:**
- `Deployment` — single replica, with readiness and liveness probes on port 80
- `Service (DNS)` — type `LoadBalancer`, pinned to dedicated MetalLB IP,
  ports 53 UDP, 53 TCP, and 9617 (Prometheus metrics)
- `Service (Web)` — type `ClusterIP`, port 80, for Traefik to route to
- `Ingress` — Traefik ingress for `pihole.houli.eu` pointing at the web service
- `PersistentVolumeClaim` — Longhorn storage class, sized appropriately for gravity DB
- `ConfigMap` — environment configuration (upstream DNS, timezone, etc.)
- `Secret` — admin password (or reference to existing secret manager pattern)

**Acceptance Criteria:**
- All resources render correctly via `helm template`
- Liveness probe: HTTP GET `/admin/` port 80
- Readiness probe: same, with appropriate initial delay
- PVC uses Longhorn storage class with 2 replicas

**Status:** Done. Using community helm chart instead

---

### PIHOLE-05 — Deploy to cluster and validate

**Type:** Testing
**Priority:** High
**Blocked by:** PIHOLE-04

**Description:**
Deploy the chart to the cluster and fully validate DNS and web UI functionality
**without touching the router**. The existing PiHole remains live throughout this task.

**Validation steps:**
```bash
# Test external DNS resolution
dig @<new-metallb-ip> google.com

# Test internal domain resolution
dig @<new-metallb-ip> sonarr.houli.eu
dig @<new-metallb-ip> jenkins.houli.eu

# Test that blocklists are working
dig @<new-metallb-ip> doubleclick.net  # should return NXDOMAIN or 0.0.0.0
```

**Acceptance Criteria:**
- Pod reaches `Running` state with both probes passing
- External DNS resolves correctly
- All `*.houli.eu` custom DNS entries resolve correctly
- A known ad domain is blocked
- `pihole.houli.eu` loads in browser (note: this resolves via the *old* PiHole at
  this stage — that is expected)
- Gravity DB is populated and blocklists match the exported config from PIHOLE-02

---

### PIHOLE-06 — Enable automatic gravity updates

**Type:** Configuration
**Priority:** Low
**Blocked by:** PIHOLE-05

**Description:**
Configure PiHole to automatically update gravity (blocklists) on a schedule.
PiHole has this capability built in via the admin UI.

**Acceptance Criteria:**
- Automatic gravity updates enabled in admin UI
- Schedule set to weekly
- Verified that the setting persists across pod restarts (i.e. is stored in the PVC)

---

### PIHOLE-07 — Cut over the router

**Type:** Ops
**Priority:** High
**Blocked by:** PIHOLE-05, PIHOLE-06

**Description:**
Update the router DNS settings to point at the new PiHole instance in the cluster.
This is the live cutover moment.

**Steps:**
1. Set primary DNS on router to the new MetalLB IP (from PIHOLE-01)
2. Set secondary DNS on router to `1.1.1.1` as a fallback
3. Monitor DNS resolution on devices for a period before decommissioning the old instance

**Acceptance Criteria:**
- Router primary DNS updated
- Router secondary DNS set to `1.1.1.1`
- DNS resolution working on multiple devices
- `pihole.houli.eu` now resolves via the new cluster instance
- No reported DNS failures after 24 hours

---

### PIHOLE-08 — Decommission the old PiHole Pi and remove legacy Ansible role

**Type:** Ops / Cleanup
**Priority:** Low
**Blocked by:** PIHOLE-07 (plus a stabilisation period — do not rush)

**Description:**
Once the cluster PiHole has been stable for a few days, decommission the standalone
PiHole Pi and clean up the legacy code that managed it. The existing Ansible role
that set up the docker-compose version of PiHole on lib-pi-06 should be deleted,
along with its playbook import.

**Acceptance Criteria:**
- Old PiHole service stopped on lib-pi-04
- Pi either repurposed or documented as available
- Legacy Ansible role for docker-compose PiHole removed from `home-lab/docker-server`
- Corresponding playbook removed from `home-lab/docker-server`
- Any firewall rules or static DHCP leases referencing the old IP cleaned up
- Repo and any network documentation updated to reflect the new IP

---

### PIHOLE-09 — Add Prometheus metrics and Grafana dashboard

**Type**: Observability
**Priority**: Low
**Blocked** by: PIHOLE-05

**Description**:
Add a pihole-exporter sidecar to the PiHole deployment to expose metrics for
Prometheus scraping, and import a community Grafana dashboard. Since Prometheus runs
externally on lib-pi-06, the metrics port is exposed on the existing DNS LoadBalancer
service — reusing the pinned MetalLB IP rather than allocating a new one or using
NodePort (which would break if the pod reschedules to a different node).

**Changes required**:
Helm chart: add pihole-exporter (ekofr/pihole-exporter) as a sidecar container in the Deployment
Helm chart: add port 9617 to the existing DNS LoadBalancer Service — Prometheus scrapes <pihole-metallb-ip>:9617
lib-pi-06 Ansible role: update Prometheus scrape config to add the new target
Grafana: import community dashboard ID 10176

**Acceptance Criteria**:
Exporter sidecar running and healthy alongside the PiHole container
Metrics reachable from lib-pi-06 on <pihole-metallb-ip>:9617
Prometheus successfully scraping the endpoint (visible in Prometheus targets UI)
Grafana dashboard showing data — query rate, blocked percentage, top blocked domains

## Summary

| Task | Type | Blocked by |
|------|------|------------|
| PIHOLE-01 | Allocate MetalLB IP | — |
| PIHOLE-02 | Export current config | — |
| PIHOLE-03 | Ansible role, playbook & Helm scaffold | PIHOLE-01 |
| PIHOLE-04 | Implement K8s resources | PIHOLE-03, Longhorn |
| PIHOLE-05 | Deploy and validate | PIHOLE-04 |
| PIHOLE-06 | Enable gravity auto-updates | PIHOLE-05 |
| PIHOLE-07 | Router cutover | PIHOLE-05, PIHOLE-06 |
| PIHOLE-08 | Decommission old Pi + remove legacy role | PIHOLE-07 + stabilisation |
| PIHOLE-09 | Prometheus metrics + Grafana dashboard | PIHOLE-05 |
