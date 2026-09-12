Status: ready-for-agent
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
