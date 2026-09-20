# ADR-0003: Pi-hole runs as two Helm releases rather than one replicated Deployment

Date: 2026-09-20
Status: Accepted

## Context

Pi-hole serves the whole house from a single Raspberry Pi. It runs as a docker
compose stack on lib-pi-04 at 192.168.1.15, managed by `docker-server/roles/pihole`.
When that Pi is down, every device on the network loses name resolution. Removing
that single point of failure is the reason for the migration, so a design that
moves the same single instance into the cluster would not be worth doing.

The migration uses the community chart `mojo2600/pihole` at version 2.35.0, whose
appVersion is 2025.11.1. That is a Pi-hole v6 release, which matters because v6
moved both the admin API and the adlist storage.

Seven facts about the chart and about Pi-hole shaped the decision. Each was read
from the chart source or the running cluster rather than assumed.

1. **Pi-hole keeps all mutable state in SQLite under `/etc/pihole`.** The query
   log, the gravity database that holds the blocklists, and the v6 web session
   store all live there. The chart mounts the volume named `config` at that path.
2. **The chart maintainer states multi-replica is unsupported.** In
   [discussion #182](https://github.com/MoJo2600/pihole-kubernetes/discussions/182)
   the reason given is that SQLite cannot take concurrent writes from several
   pods and that the v6 frontend authenticates against whichever pod served the
   request, so logins fail intermittently across replicas.
3. **The working multi-replica example puts SQLite on NFS.**
   [Issue #77](https://github.com/MoJo2600/pihole-kubernetes/issues/77) runs two
   pods against a ReadWriteMany volume with sticky sessions on the ingress.
   Longhorn can provision RWX, and doing so would place a write-ahead-logging
   SQLite database on a network filesystem.
4. **The chart's anti-affinity is built around releases, not replicas.**
   `antiaff.avoidRelease` names a Helm release, and the rendered rule matches on
   the `release` label with `topologyKey: kubernetes.io/hostname`. The chart's own
   comment gives the intended use as "2 pihole DNS in the same cluster".
5. **Two releases coexist in one namespace without collisions.**
   `pihole.fullname` in `_helpers.tpl` derives every resource name from the release
   name, so releases `pihole-1` and `pihole-2` produce disjoint sets of objects.
6. **Blocklists and DNS records are already expressible as chart values.** The
   chart renders `adlists`, `whitelist`, `blacklist`, `regex` and the dnsmasq
   settings into ConfigMaps, and the Deployment carries a checksum annotation for
   each, so editing one in the repo rolls the pods.
7. **MetalLB runs in L2 mode.** A LoadBalancer address is announced from one node
   at a time, and MetalLB only announces an address from a node holding a ready
   endpoint for it.

## Decision

Deploy Pi-hole as two Helm releases, `pihole-1` and `pihole-2`, in the `pihole`
namespace. Each runs `replicaCount: 1`.

| | `pihole-1` | `pihole-2` |
| --- | --- | --- |
| DNS address | 192.168.1.251 | 192.168.1.252 |
| Web host | `pihole-1.houli.eu` | `pihole-2.houli.eu` |
| `antiaff.avoidRelease` | `pihole-2` | `pihole-1` |
| Storage | own Longhorn PVC | own Longhorn PVC |

Both releases read the same three values files from `infra/roles/pihole/files/`,
so blocklists, whitelists, custom DNS records and host entries are defined once.
The Ansible role loops the helm task over a list of instances, and only the
release name, the address, the anti-affinity target and the ingress host differ.

Both addresses come from the MetalLB `reserved-pool`, which carries
`autoAssign: false` and therefore hands an address only to a service naming it in
its `metallb.universe.tf/loadBalancerIPs` annotation. See ADR-0002's sibling
change in `infra/roles/metallb/defaults/main.yaml` for the address map.

The DNS service uses `externalTrafficPolicy: Local`.

The router points its primary DNS at one address and its secondary at the other.

### Why not one release with two or three replicas

It is the shape the chart nominally supports, through `replicaCount`, and it is
the shape that fails. Several pods writing one SQLite database is the failure
mode fact 2 describes, and fact 3's workaround relocates that database onto NFS,
which turns a concurrency problem into a locking-over-network problem. The web UI
would additionally need sticky sessions to stay usable.

### Why not one release with several replicas and no volume at all

Discarding the volume removes the shared-SQLite problem, because each pod becomes
independent and boots its configuration from the ConfigMaps. It was the closest
alternative. It loses the query log on every pod restart, and with several pods
behind one address the dashboard shows only whatever the pod serving the browser
happened to answer. The per-client and per-domain history is most of the value of
running Pi-hole rather than a plain forwarder.

### Why not a sync tool such as nebula-sync

Gravity Sync is archived and [nebula-sync](https://github.com/lovelaze/nebula-sync)
replaces it for v6, propagating settings between instances over the API. It solves
keeping two hand-edited instances in agreement. Both releases here read the same
values files out of the repo, so their configuration is identical by construction
and there is nothing for a sync tool to reconcile. Adding one would introduce a
second source of truth competing with the repo.

### Why the query logs are allowed to diverge

Each instance sees only the queries it answered, so neither dashboard shows the
whole picture. Accepting that is what keeps each instance independent. The
alternative is shared state, which is the thing every option above founders on.

### Why `externalTrafficPolicy: Local`

Under `Cluster`, the node receiving a query forwards it to a pod on any node and
rewrites the source address to its own so the reply returns by the same path.
Pi-hole then attributes every query to a handful of node addresses, which empties
the Top Clients view and leaves Pi-hole's per-client group feature with nothing to
match on. `Local` forwards only to a pod on the receiving node, needs no rewrite,
and preserves the client address.

`Local` normally costs load spreading, because only the pod on the announcing node
receives traffic. That cost does not apply here. Each release has one pod and its
own address, and by fact 7 MetalLB announces an address only from a node with a
ready endpoint, so the announcing node is always the node running that pod.

### Why two addresses rather than one shared between both instances

One address would make the pair a single MetalLB announcement. Failing over would
mean MetalLB withdrawing the address from one node and announcing it from another,
during which queries time out. With two addresses the client does the failover
itself, using the secondary DNS server it was already configured with.

## Consequences

- Losing a node takes out one instance. Clients fall back to the other through
  their secondary DNS setting, with no cluster-side failover involved.
- There are two dashboards and no combined view. Answering "was this domain
  blocked" may mean checking both.
- Blocklist changes are made once in `infra/roles/pihole/files/adlist.yaml` and
  reach both instances on the next playbook run.
- A PodDisruptionBudget must not be added. With `minAvailable: 1` against a
  single-replica Deployment the eviction API refuses to evict the only pod, and
  `kubectl drain` on that node hangs indefinitely.
- Two of the three reserved MetalLB addresses are consumed, leaving .250 for
  Traefik and nothing spare inside the reserved pool.
- The old instance on lib-pi-04 stays live through deployment and validation, so
  there is no window where the house depends on the new instances before they
  have been tested.

## Open questions

Whether the adlist and whitelist ConfigMaps actually seed a v6 gravity database
has not been verified. The chart mounts them as individual files at
`/etc/pihole/adlists.list` and `/etc/pihole/whitelist.txt`, which are v5 paths,
inside the directory the PVC occupies, and the chart's own wording is that they
are imported "during initial start of the container". Pi-hole v6 stores adlists
in `gravity.db`. If the seed only applies to an empty database, a later edit in
the repo would roll the pods without changing what is blocked, and the blocklists
would be config-as-code in appearance only. This must be settled on first deploy,
before the router is cut over.

Pointing the cluster's own nodes at DNS that runs on those nodes creates a
start-up ordering dependency. `infra/roles/set_static_ip` writes `pihole_dns_ip`
as each node's resolver and `infra/roles/k3s_config` forwards `houli.eu` and
`home` to it from CoreDNS. What those should fall back to during a cold start of
the whole cluster is deferred to the cutover, PIHOLE-07.
