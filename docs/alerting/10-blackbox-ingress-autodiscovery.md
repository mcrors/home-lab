# Task: Auto-discover Blackbox Probe Targets from Ingresses

Status: in progress. The discovery job is live and proven; the ingress annotations are being
rolled out one service at a time.

## Done

- ClusterRole `prometheus-scraper` granted `list`/`watch` on `networking.k8s.io/ingresses` (`8680dc9`)
- `blackbox-ingress` scrape job added to `prometheus.yml.j2` (`4a86c7f`), running alongside
  `blackbox-http`
- Verified on lib-pi-06: 12 ingresses discovered, opt-in filter working, no discovery errors
- `plex` annotated and probing green through the new job, exercising the path override

## Remaining

- Annotate the other 11 ingresses
- Shrink `blackbox-http` to `omv`, `prometheus`, `traefik`
- Add the empty-target guard alert (see `alerts-to-create.md`)
- Decide whether both blackbox jobs should carry the `cluster` label added in `2deb3d3`

Replace the hand-maintained `blackbox-http` target list with Kubernetes service discovery, so new
services are probed without editing `prometheus.yml.j2`.

## Why

The target list at `infra/roles/prometheus/templates/prometheus.yml.j2:84` is static. Three live
ingresses are currently unprobed: `alertmanager.houli.eu`, `ntfy.houli.eu`, `uptime.houli.eu`.
Those three are the alerting pipeline itself, so a failure there is invisible to the system meant
to report it.

## Approach

Add a `kubernetes_sd_configs` job with `role: ingress`, keeping only ingresses that carry a
`prometheus.io/probe: "true"` annotation, and relabelling to build the probe URL from the ingress
host and path.

Optional per-ingress annotations:

| Annotation | Purpose |
|---|---|
| `prometheus.io/probe` | `"true"` to opt in |
| `prometheus.io/probe-module` | Override the default `http_2xx` (needed for auth-protected endpoints) |
| `prometheus.io/probe-path` | Probe a specific path, e.g. `/login` for Jenkins, `/web/index.html` for Plex |

## Constraints specific to this setup

- **Prometheus is external** (Docker Compose on lib-pi-06), so SD needs API server access. Extend
  the existing `prometheus-scraper` ClusterRole with `networking.k8s.io` / `ingresses` /
  `[list, watch]`. The token is already plumbed through as `prometheus_scraper_token`.
- **`role: ingress` only sees `networking.k8s.io/v1` Ingress objects.** `traefik.houli.eu` is a
  Traefik `IngressRoute` CRD and will not be discovered. Keep it static.
- **External targets stay static**: `omv.houli.eu`, `prometheus.houli.eu`, `jenkins.houli.eu` are
  not in the cluster. The result is a hybrid of one SD job plus a smaller static job.

## Silent failure mode

Wrong RBAC or a mistyped annotation yields an empty target list and no alert. `PrometheusTargetDown`
does not catch "zero targets". Use `prometheus_sd_discovered_targets{config="blackbox-ingress"}` to
tell "discovery found nothing" apart from "discovery worked and the filter dropped everything", and
add an explicit guard once annotations exist:

```promql
absent(up{job="blackbox-ingress"}) or count(up{job="blackbox-ingress"}) == 0
```

## Knock-on benefit

Ingress SD attaches `namespace` and ingress name as target labels. That gives probe alerts and
kube-state-metrics alerts a shared label to join on, which is the prerequisite for the inhibit
rules in `11-alert-grouping-and-inhibition.md`.

## Dependencies

- The `networking` alert group must actually be deployed first (see `alerts-to-create.md` — the
  repo and lib-pi-06 have drifted).
