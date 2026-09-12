Status: ready-for-agent
Blocked by: nothing

# Scaffold the Homepage Helm chart

## Context

No community Homepage chart is maintained well enough to depend on, so the chart is ours.
`services/helm/prowlarr/` is the reference: copy its `Chart.yaml`, `_helpers.tpl`, and template
layout, then strip the persistence machinery, which Homepage does not need.

This ticket produces a chart that lints and renders. It does not deploy anything.

See `docs/homepage/homepage-project-plan.md` row HOM-01.

## Scope

Create `services/helm/homepage/` with:

- `Chart.yaml`, `values.yaml`, `templates/_helper.tpl` (singular, matching the Prowlarr chart)
- `ServiceAccount`
- `ClusterRole` — read (`get`, `list`) on `namespaces`, `pods`, `nodes`, `ingresses` (`networking.k8s.io`), `ingressroutes` (`traefik.io`), and `nodes`/`pods` in `metrics.k8s.io`
- `ClusterRoleBinding` binding that role to the ServiceAccount
- `ConfigMap` with keys `settings.yaml`, `services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `kubernetes.yaml`, `custom.css`, `custom.js`. Ticket 02 fills them; leave them minimal but valid here.
- `Deployment` — one replica, the ServiceAccount with `automountServiceAccountToken: true`, `HOMEPAGE_ALLOWED_HOSTS` from values, the ConfigMap mounted **per file with `subPath`** plus an `emptyDir` at `/app/config/logs`, and `nodeSelector`/`tolerations`/`affinity` rendered with the same `{{- with }}` guards as `services/helm/prowlarr/templates/deployment.yaml` lines 77-88
- `Service` — ClusterIP on port 3000
- `Ingress` — `ingressClassName: traefik`, `websecure` entrypoint, wildcard TLS through the cluster TLSStore, following the Ingress template of the Prowlarr chart

A ConfigMap change does not restart a Deployment by itself, and `subPath` mounts are never refreshed
by the kubelet even when it does. Add a checksum annotation on the pod template
(`checksum/config: {{ include (print $.Template.BasePath "/configMap.yaml") . | sha256sum }}`)
so a config edit actually reaches the running pod.

`values.yaml` ships `nodeSelector: {}` and the real affinity block comes from the role's values file
in ticket 03, matching how every other chart here splits chart defaults from cluster specifics.

## Acceptance criteria

- `helm lint services/helm/homepage` passes with no errors.
- `helm template services/helm/homepage` renders every resource above.
- Rendering with the ticket-03 affinity values produces a `node_size In ["medium"]` term.
- The ConfigMap carries every config key and the Deployment mounts each one.
- `kubectl apply --dry-run=server` accepts the rendered output.

## Comments

Chart written. `helm lint` clean, `helm template` renders all seven resources, and
`kubectl apply --dry-run=server` accepts every one of them against the live cluster. Nothing was
deployed; ticket 03 does that.

Three things in the original scope were wrong, checked against gethomepage.dev and corrected above:

1. The ConfigMap cannot be mounted as a directory over `/app/config`. Homepage writes its logs into
   `/app/config/logs`, and a directory mount hides that path. Each key is mounted individually with
   `subPath`, with an `emptyDir` at `/app/config/logs`. `subPath` mounts also never pick up a
   ConfigMap change, which turns the checksum annotation from a nicety into the only thing that makes
   a config edit take effect.
2. The ServiceAccount needs `automountServiceAccountToken: true`. The Prowlarr chart sets it to
   `false` and that is right for Prowlarr, which never calls the API. Homepage does.
3. The ClusterRole needs `traefik.io/ingressroutes`, which the original list omitted. The cluster has
   both the `traefik.io` and `gateway.networking.k8s.io` CRDs installed.

Decisions taken while writing it:

- Config files are a `config:` map in values, filename to content. The Deployment builds its mounts
  by ranging over that same map, so a new key is mounted with no template change and the mount list
  cannot drift from the ConfigMap. It also removes a sharp edge: a `subPath` naming a key that does
  not exist leaves the pod stuck in `ContainerCreating`.
- Gateway API permission is not granted. The CRDs exist because k3s ships them with Traefik, but
  nothing in the cluster routes through them. `rbac.gateway` in values turns the rules on if that
  changes; it is off, and `kubernetes.yaml` should leave `gateway` off to match.
- The ClusterRole and ClusterRoleBinding names fold in the release namespace. Those objects are
  cluster-scoped, so two installs of this chart in different namespaces would otherwise overwrite
  each other's permissions.
- `HOMEPAGE_ALLOWED_HOSTS` always includes the pod IP, taken from the downward API. The probes
  connect straight to the pod IP, and homepage answers 400 to any host not on the list, so without
  it the pod would never pass its readiness probe.
- Runs as non-root, UID/GID 1000, all capabilities dropped. `readOnlyRootFilesystem` is left off:
  the app writes at runtime and the full set of paths is not knowable without running it, so
  guessing a list would fail later on whichever path was missed. `securityContext` is a values
  passthrough, so turning it on needs no template change. Ticket 03 tries it against a live pod.
- Pinned to `appVersion: v2.3.0`, the current release, rather than `latest`.

Revisited under a "what if this were a shared chart" framing. No chart change needed: Helm's
`--set-file` reads a real file at install time and assigns it to a values key, so config content
never has to be pasted into a values file. Verified against this chart —
`helm template . --set-file 'config.custom\.css=./custom.css'` renders the stylesheet into the
ConfigMap with the other keys keeping their defaults, and `kubernetes.core.helm` reaches the same
flag through a `set_values` entry with `value_type: file`. Only the path travels on the command
line, so file size is not a constraint.

The one sharp edge is escaping: keys are filenames, so the dot needs `config.custom\.css`. Left
unescaped, Helm reads it as nesting and builds `config.custom.css` three levels deep instead of
setting the key, with no error. Renaming the keys to escape-free identifiers (`customCss`) with a
filename mapping in the chart would remove that, at the cost of fixing the file set in the template.
Not taken; the escaping is recorded in ticket 03 with a `kubectl` check that catches it.
