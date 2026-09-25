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

## Current state (2026-09-25)

Both instances are deployed, serving all cluster DNS, and under monitoring. The
house is still entirely on the old instance at 192.168.1.15: the router has not
been touched, so nothing a phone, laptop or TV does has changed.

The design is recorded in `docs/adr/0003-pihole-as-two-helm-releases.md`. Two
single-replica Helm releases rather than one replicated Deployment, because
Pi-hole keeps its query log, gravity database and web sessions in SQLite and
several pods cannot share them.

| | |
| --- | --- |
| `pihole-1` | 192.168.1.251, `pihole-1.houli.eu` |
| `pihole-2` | 192.168.1.252, `pihole-2.houli.eu` |
| Lists | 30 adlists, 194 allowed domains, reconciled from the repo |
| Cluster DNS | CoreDNS forwards `houli.eu` and `home` to both |
| Clients | still the old instance on .15 |

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

**Status:** Done, and wider than written. Two addresses were needed rather than
one, .251 and .252, held in `infra/vars/main.yaml` as `k3s_pihole_1_dns_ip` and
`k3s_pihole_2_dns_ip`.

Reservation was not implemented at the time. The pool auto-assigned, so any
LoadBalancer service could take these addresses, and one already had: the MetalLB
smoke test held .251 for 165 days because it never tore itself down. MetalLB is
now split into `reserved-pool` at .250-.252 with `autoAssign: false` and
`default-pool` at .253-.254. A reserved address goes only to a service naming it
in a `metallb.universe.tf/loadBalancerIPs` annotation, which is how Traefik holds
.250 and how both Pi-hole instances hold theirs.

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

**Status:** Done. Both instances validated against .251 and .252: external names,
every `*.houli.eu` and `.home` record, three known ad domains blocked, three
allowlisted domains resolving, and TCP 53 alongside UDP. Anti-affinity placed the
pods on separate nodes without being asked twice.

The hostnames are `pihole-1.houli.eu` and `pihole-2.houli.eu` rather than the
single `pihole.houli.eu` this ticket assumed. The instances keep separate query
logs, so a shared name would hide which one you were reading.

Two things this validation would have missed, both now covered by the role:

`pihole-2` spent half an hour resolving every name correctly, passing both
probes, and blocking nothing, because its first-boot gravity build was killed
part way through and Pi-hole does not retry once `gravity.db` exists. Resolution
is not evidence an instance works. The role now asserts a known ad domain returns
`0.0.0.0` as well as a local record resolving, per instance, before moving on.

The mounted `adlists.list` is read only once, by `gravity.sh`'s
`migrate_to_database`, which runs when `gravity.db` does not exist. An edit to
`adlist.yaml` reached the file and stopped there. `files/reconcile-lists.sh`
now brings the database into line with the mounted files through the REST API
before each gravity rebuild.

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

**Status:** Effectively done by two mechanisms, with the third criterion not met
and not worth meeting.

The image ships a weekly cron already, at `/etc/crontabs/root` rather than the
`/etc/cron.d/pihole` most guides name, since this is a busybox layout. Each
install picks its own random time on Sunday: `pihole-1` runs 03:36, `pihole-2`
04:13. The two differ, so a redundant pair never rebuilds at the same moment.

The role also rebuilds gravity on every playbook run, controlled by
`pihole_update_gravity`. That exists because Pi-hole downloads the lists once on
first boot and never again on its own, so without it an `adlist.yaml` edit
changes nothing that blocks.

The third criterion is not met. `/etc/crontabs/root` is in the container
filesystem, not on the PVC, so it is regenerated on every container start with a
fresh random time. The schedule survives in the sense that a weekly run always
exists; the specific time does not. There is nothing to fix here, only something
not to be surprised by.

Note the cron runs `pihole updateGravity`, which is the same command as
`pihole -g`. It refreshes the contents of the subscribed lists and has no way to
notice a list added or removed in the repo. That is what the reconcile in
PIHOLE-05 is for.

---

### PIHOLE-07 — Cut over the router

**Type:** Ops
**Priority:** High
**Blocked by:** PIHOLE-05, PIHOLE-06

**Description:**
Update the router DNS settings to point at the new PiHole instance in the cluster.
This is the live cutover moment.

**Steps:**
1. Set primary DNS on router to 192.168.1.251 and secondary to 192.168.1.252
2. Monitor DNS resolution on devices for a period before decommissioning the old instance

**Acceptance Criteria:**
- Router primary and secondary DNS point at the two instances
- DNS resolution working on multiple devices
- `pihole-1.houli.eu` and `pihole-2.houli.eu` resolve via the new instances
- No reported DNS failures after 24 hours

**Status:** Not started. The cluster half is already done and soaking.

`1.1.1.1` as a secondary is deliberately dropped. That is standard advice for a
single Pi-hole and it is the usual way people end up with blocking that works
intermittently, because routers and clients do not treat a secondary as
failover-only. A share of traffic would bypass Pi-hole permanently. Two instances
on two nodes is the redundancy, so no public fallback is wanted.

The CoreDNS half landed separately on 2026-09-25, commit `60db972`. Pods have
been resolving `houli.eu` and `home` through both instances since. That soak
immediately found six hostnames the repo had no records for, fixed in `c9420ad`.

Confirmed about this network: the router hands clients the upstream address
directly rather than its own, so after this change every client talks to a
Pi-hole instance and gets both addresses. Failover happens at the client, which
is what two instances were for. It is also why `externalTrafficPolicy: Local`
matters, since Pi-hole will see real client addresses rather than the router.

Blocked on PIHOLE-10 as well, so the nodes are off the old address first.

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
- The old instance's full local DNS list is diffed against `files/dnsmasq.yaml`
  and anything only on the old box is brought into the repo
- Old PiHole service stopped on lib-pi-04
- Pi either repurposed or documented as available
- Legacy Ansible role for docker-compose PiHole removed from `home-lab/docker-server`
- Corresponding playbook removed from `home-lab/docker-server`
- Any firewall rules or static DHCP leases referencing the old IP cleaned up
- Repo and any network documentation updated to reflect the new IP
- `pihole_dns_ip` removed from `infra/vars/main.yaml` once nothing references it

**Status:** Not started.

The first criterion is new and is the reason not to rush this. The old instance
held six records the repo never had, added through its UI over the years:
`traefik`, `alertmanager`, `ksm`, `ntfy`, `plex.houli.eu` and `uptime`. They only
surfaced because the CoreDNS cutover started failing probes. Six were found by
accident, so the rest of that box's state should be compared deliberately before
it is switched off rather than assumed to be empty.

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

**Status:** Not started, and the shape has changed.

Availability monitoring is already done, which this ticket did not cover. Both
ingresses carry `prometheus.io/probe` and are discovered by the `blackbox-ingress`
job. `/` returns 403, so `prometheus.io/probe-path` points at `/admin/login`, the
same way jenkins needed `/login`. Both targets are UP.

What remains is the Pi-hole metrics themselves. Three things differ from the plan
as written:

- The chart has `monitoring.sidecar` built in, using the same
  `ekofr/pihole-exporter` this ticket names, so no chart change is needed.
- There are two instances, so two scrape targets, and the dashboard needs to
  distinguish them or aggregate deliberately.
- The metrics port does not need adding to the DNS LoadBalancer. Prometheus runs
  on lib-pi-06 outside the cluster, but the blackbox pattern already in use shows
  an ingress is the simpler route than widening a LoadBalancer service.

---

### PIHOLE-10 — Point the nodes at the gateway for DNS

**Type**: Infrastructure
**Priority**: High
**Blocked by**: PIHOLE-05

**Description**:
`infra/roles/set_static_ip` writes `pihole_dns_ip` as the nameserver on every
node. Pointing that at an in-cluster address would make the machines running
Pi-hole resolve DNS through Pi-hole. Steady state is fine; a cold start is not,
because a node needs DNS to resolve a registry hostname to pull the very image
that provides DNS. Containerd usually still has the image cached, so a plain
reboot recovers, but a fresh or wiped node would not.

The gateway resolves independently. Verified: `192.168.1.1` answers public names
and serves `.home` from its own DHCP table, and does not forward to Pi-hole, so
it does not block ads and does not know `*.houli.eu`. Nodes need neither. Ad
blocking does nothing for a machine that fetches container images and apt
packages, pods resolve through CoreDNS rather than the node resolver, and nothing
at node level reaches a `.houli.eu` name. The Longhorn backup target is an
address, not a hostname.

Pointing nodes at the gateway therefore breaks the dependency rather than moving
it, and the recovery for a total Pi-hole outage becomes one router setting rather
than reconfiguring nine nodes.

**Acceptance Criteria**:
- `static-netplan.yaml.j2` uses `gateway` instead of `pihole_dns_ip`
- Applied to one node first and confirmed Ready and resolving, then the rest
- Every node resolves public names and `.home` names
- The cluster survives a node reboot with the new resolver

**Note**: the play is `infra/playbooks/common.yaml`, tagged `static_ip`, against
`all_nodes`. Its handlers run `netplan apply` and restart `systemd-networkd`,
`systemd-resolved` and `dhcpcd`, so this is real network reconfiguration on all
nine nodes including the control plane. `netplan apply` runs `async: 1, poll: 0`,
which means Ansible does not wait to learn whether it worked.

**Status**: Not started.

## Summary

| Task | Type | Blocked by | Status |
|------|------|------------|--------|
| PIHOLE-01 | Allocate MetalLB IP | — | Done |
| PIHOLE-02 | Export current config | — | Won't do |
| PIHOLE-03 | Ansible role, playbook & Helm scaffold | PIHOLE-01 | Done |
| PIHOLE-04 | Implement K8s resources | PIHOLE-03, Longhorn | Done |
| PIHOLE-05 | Deploy and validate | PIHOLE-04 | Done |
| PIHOLE-06 | Enable gravity auto-updates | PIHOLE-05 | Done |
| PIHOLE-10 | Point nodes at the gateway | PIHOLE-05 | Not started |
| PIHOLE-07 | Router cutover | PIHOLE-05, PIHOLE-06, PIHOLE-10 | Not started |
| PIHOLE-08 | Decommission old Pi + remove legacy role | PIHOLE-07 + stabilisation | Not started |
| PIHOLE-09 | Prometheus metrics + Grafana dashboard | PIHOLE-05 | Not started |

Parked by choice: an adult-content blocklist, a homepage widget showing query
counts and block percentage, and sorting `adlist.yaml` down from its current 30
overlapping lists.
