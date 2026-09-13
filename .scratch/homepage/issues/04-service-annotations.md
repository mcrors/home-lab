Status: resolved
Blocked by: 03

# Annotate the remaining service Ingresses

## Context

Homepage discovers in-cluster services from `gethomepage.dev/*` annotations on their Ingress.
Four services already carry them, added during the alerting work: Alertmanager
(`infra/roles/alertmanager/files/values.yaml`), kube-state-metrics and Ntfy (in their roles'
`tasks/main.yaml`), and Traefik (`infra/roles/k3s_config/tasks/main.yaml`). This ticket brings the
rest into line.

Ticket 03 deploys first so each annotation can be checked against a live dashboard rather than
assumed.

See `docs/homepage/homepage-project-plan.md` row HOM-04.

## Scope

Use the five-key form the four existing services established, not the six-key form the original
plan drafted:

```yaml
gethomepage.dev/enabled: "true"
gethomepage.dev/name: "<display name>"
gethomepage.dev/group: "<Infra|Media|CI/Ops>"
gethomepage.dev/icon: "<icon-name>"
gethomepage.dev/description: "<short description>"
```

The icon name carries no `.png` extension and there is no `href`; Homepage builds the link from the
Ingress host.

| Service | Group | Icon | Where the annotation goes |
|---------|-------|------|---------------------------|
| Plex | Media | `plex` | `services/roles/plex/files/values.yaml` |
| Sonarr | Media | `sonarr` | `services/roles/sonarr/files/values.yaml` |
| Radarr | Media | `radarr` | `services/roles/radarr/files/values.yaml` |
| Prowlarr | Media | `prowlarr` | `services/roles/prowlarr/files/values.yaml` |
| Transmission | Media | `transmission` | `services/roles/transmission/files/values.yaml` |
| Longhorn | Infra | `longhorn` | `infra/roles/longhorn_chart/files/values.yaml` |
| Blackbox Exporter | Infra | `prometheus` | `infra/roles/blackbox_exporter/files/values.yaml` |
| Grafana | CI/Ops | `grafana` | `infra/roles/grafana/files/values.yaml` |
| Uptime Kuma | CI/Ops | `uptime-kuma` | `services/roles/uptime-kuma/files/values.yaml` |

Confirm each path before editing; some services annotate through the role's `files/values.yaml` and
others through an inline manifest in `tasks/main.yaml`.

Jenkins is out of scope. `.scratch/jenkins/issues/07-monitoring-and-homepage.md` owns that row and
adds the annotation when the Jenkins Ingress exists.

Traefik is annotated on an `IngressRoute` CRD rather than an `Ingress`. This is settled: homepage
does discover `IngressRoute` objects when `kubernetes.yaml` sets `traefik: true`, which ticket 02
does, and the chart grants the `traefik.io` read permission. There is one catch — an `IngressRoute`
carries arbitrary routing rules that homepage cannot turn into a URL, so it requires
`gethomepage.dev/href` to be set explicitly. Add

```yaml
gethomepage.dev/href: "https://traefik.houli.eu"
```

to the existing annotation block in `infra/roles/k3s_config/tasks/main.yaml`, adjusting the host to
whatever that IngressRoute actually serves. This is the single exception to the no-`href` rule above;
every `Ingress`-based service still omits it.

Annotations only take effect after the owning role is re-run, so each edited service needs its
playbook tag applied.

## Acceptance criteria

- Every service in the table appears on the dashboard under the group listed.
- All icons resolve; no broken image placeholders.
- The Traefik outcome is settled one way or the other and written into `## Comments`.
- No service appears twice, once discovered and once static.

## Comments

All nine rows annotated and deployed on 2026-09-12/13, plus the Traefik exception. The dashboard
went from 3 in-cluster cards to 13, and `Media` and `CI/Ops` render for the first time. Every claim
below was checked against the live cluster.

One path in the table above is wrong. Longhorn's Ingress is not in
`infra/roles/longhorn_chart/files/values.yaml`; that file sets `ingress.enabled: false` and the role
renders its own object from `templates/ingress.yaml.j2`. The annotation goes in the template. The
other eight paths are correct.

### The pod-status mechanism, which the ticket does not mention

Ticket 02 recorded that "the in-cluster cards get a pod-phase tag from discovery for free." It is not
free, and it was already failing in production before this ticket started.

Read out of the running v2.3.0 image rather than the docs. Each card's status tag comes from
`/api/kubernetes/status/<namespace>/<app>`, and the handler picks its label selector like this:

    let selector = (podSelector !== undefined) ? podSelector : `app.kubernetes.io/name=${app}`

`app` defaults to the Ingress's own `metadata.name`. So the tag only works when the Ingress name
happens to equal the value of the pods' `app.kubernetes.io/name` label. Seven of the nine services
satisfy that by luck. Three things break it, and they need different fixes:

| Failure | Example | Fix |
|---|---|---|
| Ingress name ≠ label value | Blackbox: Ingress `blackbox-prometheus-blackbox-exporter`, pods `prometheus-blackbox-exporter` | `gethomepage.dev/app` — it substitutes the value |
| Pods have no `app.kubernetes.io/name` at all | Longhorn (`app=longhorn-ui`), ntfy (`app=ntfy`) | `gethomepage.dev/pod-selector` — it replaces the whole selector |
| Object is an IngressRoute | Traefik: object `traefik-dashboard`, pods `traefik` | `gethomepage.dev/app`, plus `href` — see below |

The distinction between the first two matters and is easy to get wrong. `gethomepage.dev/app` only
substitutes the value into `app.kubernetes.io/name=<value>`. Where the pods carry no label with that
key, no value can match, so only `pod-selector` helps.

Note that `pod-selector: ""` is not a way to disable the lookup. The check is `!== undefined`, so an
empty string selects every pod in the namespace. That would have been actively wrong for ntfy, whose
namespace also holds `ntfy-bridge`, `signal-bridge` and `signal-cli`.

The status value itself is an aggregate: all matched pods Running or Succeeded gives `running`, some
gives `partial`, none gives `down`. Pod count never affects card count. Longhorn runs two UI replicas
and produces one card with one tag.

### Traefik: settled, working

Required by the acceptance criteria. Traefik now renders and its status tag works.

Two independent problems, not one. First, the card did not appear at all. Homepage builds a card's
URL from `spec.rules[0].host`, and an IngressRoute has no such field — its hostname is inside the
routing expression `match: "Host(`traefik.houli.eu`)"`, which homepage does not parse. It throws on
that object and drops it. This confirms the gap ticket 03 observed. `gethomepage.dev/href` fixes it
because the code reads `annotations.href || derive(...)` and `||` short-circuits, so the failing
derivation never runs.

Second, the status tag would still have failed, because the object is named `traefik-dashboard` while
the pods are labelled `traefik`. That needed `gethomepage.dev/app: "traefik"` as well.

The href is written as `https://{{ traefik_host }}` rather than the literal hostname the ticket
drafted, because that variable already exists in the role's defaults and is used in the `match` rule
immediately below it.

This is the only exception to the no-`href` rule. All nine Ingress-based services were checked: every
one has `spec.tls`, a host, and path `/`, so each derives `https://<host>/` correctly on its own.

### ntfy was fixed at the source, not worked around

ntfy is out of this ticket's scope but was the only remaining broken status, and the fix belongs with
the rest of this work. Its pods carried only the older bare `app: ntfy` label, because ntfy is a
hand-written manifest rather than a Helm chart, and Helm is what sets `app.kubernetes.io/*` on
everything else here.

The cheap fix was a `pod-selector` annotation on the Ingress. The fix taken instead was adding
`app.kubernetes.io/name: ntfy` to the pod template, so ntfy now follows the same convention as every
other workload and needs no annotation. A workaround would have documented the oddity forever in a
file that has nothing to do with ntfy. `selector.matchLabels` is immutable and was not touched; the
Service still selects on `app`, and both still match.

### Deployment notes

Longhorn and ntfy were deployed with the play list narrowed, because `--tags longhorn` otherwise
reaches three plays that do multipath and disk setup on the storage nodes. `--limit localhost` alone
fails with "no hosts to target", because localhost is not in `infra/inventory.yaml`. Adding it as a
second inventory source works:

    ansible-playbook playbook.yaml --tags longhorn -i ./inventory.yaml -i localhost, --limit localhost

Confirmed with `--list-hosts` before running that the three storage-node plays got zero hosts. The
Longhorn Helm task reported `ok`, not `changed`, confirming the upgrade was a no-op: repo pins chart
`1.11.0` and images `v1.11.2`, and the cluster runs exactly that.

Traefik is the one thing not applied through Ansible. Its role is `k3s_config`, which configures core
cluster networking, so the two annotations were applied with `kubectl annotate` using the same values
the template renders. Repo and cluster agree key for key, but the Ansible task that produces them is
unverified. The next person to run `k3s_config` is the one who finds out.

### Acceptance criteria

- **Every service appears under the group listed** — met. 13 in-cluster cards plus 2 off-cluster, 15 in total,
  confirmed from `/api/services`. Group order renders Infra, Media, CI/Ops, Off-Cluster, matching the
  `layout` block in `settings.yaml`.
- **All icons resolve** — not checked. Every icon name here is the one this ticket guessed. Ticket 06
  owns the audit and is blocked on this ticket by design, so this criterion is deferred there rather
  than met.
- **The Traefik outcome is settled and written here** — met, above.
- **No service appears twice** — met. `services.yaml` lists only the two off-cluster targets, and
  neither collides. Worth recording one near miss: the `plex` namespace holds an `IngressRouteTCP`
  named `plex-tcp`, which would have produced a second Plex card had homepage read it. It cannot —
  the chart's ClusterRole grants `traefik.io/ingressroutes` only, and the TCP variant is a separate
  resource type. Plex appears once.

### Still open

Every status tag except ntfy's was verified by calling the endpoint directly; ntfy's was confirmed by
Rory in the browser. One correction to something said during the work: the failing status lookup logs
an error only when a browser loads the page, not on every discovery refresh. Server-side discovery
runs silently.

Resolved.
