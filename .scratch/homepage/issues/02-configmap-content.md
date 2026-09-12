Status: ready-for-human
Blocked by: 01

# Write the ConfigMap content

## Context

The chart from ticket 01 has empty config keys. This ticket writes the real configuration.
`docs/homepage/homelab-dashboard.html` is the visual target for `custom.css`.

See `docs/homepage/homepage-project-plan.md` row HOM-02.

## Scope

**`kubernetes.yaml`** — `mode: cluster`, plus `ingress: true` and `traefik: true`. The Traefik flag
turns on `IngressRoute` discovery, which is how the Traefik dashboard card appears; the chart already
grants the matching RBAC. Leave `gateway` off: the Gateway API CRDs exist in this cluster but nothing
routes through them, and the chart grants no permission for them.

**`settings.yaml`** — title `houli.eu`, dark theme, and the group order `Infra`, `Media`, `CI/Ops`
so discovered services land in a stable layout.

**`widgets.yaml`** — the Kubernetes cluster widget (CPU, memory, node count), the Kubernetes nodes
widget (per-node CPU and memory), and a DuckDuckGo search bar.

**`services.yaml`** — off-cluster targets only. Anything with a k8s Ingress is discovered, never
listed here.

- NAS admin UI (OMV on the Radxa Penta HAT Pi)
- lib-pi-06: Prometheus, Garage S3
- The Postgres data node

Confirm each host and port against the live machine before writing it down; the repo and lib-pi-06
have drifted before.

**`bookmarks.yaml`** — the GitHub repo, and anything else worth one click.

**`custom.js`** — leave it empty. The chart ships the key because homepage expects the file, and an
empty string is a valid value.

**`custom.css`** — the terminal aesthetic from the mockup: IBM Plex Mono, background `#0d0f11`
with the subtle grid overlay, accents `#3b82f6` and `#22d3ee`, card borders, muted labels,
monospace data values. The font must be self-hosted or already present; a webfont fetched from a
third party puts a public dependency in front of an internal dashboard.

## Where these files live

Every one of them is a real file in `services/roles/homepage/files/`, named exactly as Homepage
expects it: `settings.yaml`, `services.yaml`, `widgets.yaml`, `bookmarks.yaml`, `kubernetes.yaml`,
`custom.css`, `custom.js`. None of this content goes into a values file. Ticket 03 passes each one
with `--set-file`, verified against the chart as built.

Author them as plain YAML and plain CSS. Do not be tempted to write the YAML ones as native
structures in a values file and let the chart serialise them: Go templating sorts map keys
alphabetically, and the key order of the `layout` block in `settings.yaml` is what sets the display
order of the groups on the page. Serialising through the chart would silently re-sort the dashboard.
`--set-file` copies the file as written, so the order you choose is the order that ships.

## Acceptance criteria

- `helm template` renders and every key parses as valid YAML.
- Off-cluster entries appear under their own group, separate from discovered services.
- The page matches the mockup closely enough to be recognisably the same design, with no CSS errors in the browser console.

## Comments

Written and verified against a real homepage v2.3.0 container running locally with these exact seven
files mounted and a kubeconfig for the live cluster, so discovery, the Kubernetes widget, and every
setting were checked against the binary rather than against the docs. `helm template` with all seven
`--set-file` flags renders each key byte-identical to the file on disk, the Deployment mounts all
seven, and `kubectl apply --dry-run=server` accepts the result.

Three off-cluster targets in the plan were wrong, checked against the live machines:

1. **Garage S3 does not exist.** lib-pi-06 runs two containers, `nginx_reverse_proxy` and
   `prom/prometheus:v3.5.0`, and nginx serves one `server_name`, `prometheus.houli.eu`. Nothing
   listens on 3900 there or anywhere else on the network.
2. **Postgres does not exist.** `postgres.houli.eu` has a Pi-hole DNS record pointing at
   192.168.1.226, but nothing listens on 5432 on that host, lib-hp-01, or lib-pi-04. The record is
   stale and worth removing separately.
3. **The NAS is not a Radxa Penta HAT Pi.** `omv.houli.eu` is 192.168.1.96, which is lib-hp-01, a
   Debian 11 HP box serving OMV over plain nginx on port 80. Port 443 refuses the connection, so the
   entry is `http://`.

`services.yaml` therefore lists two off-cluster services, not four.

Decisions taken while writing it:

- `siteMonitor` on both off-cluster entries. Homepage pings the URL and renders the latency as a tag,
  which is the nearest equivalent of the mockup's status dot and says more than a dot does. The
  in-cluster cards get a pod-phase tag from discovery for free.
- `hideVersion: true` and `disableCollapse: true`, neither of which the ticket asked for. Collapsing
  hides the thing the page exists to show, and the release is pinned in `Chart.yaml` where git
  records it. Both verified to take effect.
- `headerStyle: underlined`, because it already renders a heading plus a rule, which is what the
  mockup's section header is. The stylesheet reshapes that rule rather than inventing one.
- The off-cluster group is named `Off-Cluster` and is last in the `layout` block. Empty groups do not
  render, so `Media` and `CI/Ops` are invisible until ticket 04 annotates something into them.

On `custom.css`: homepage's documentation says you can "target elements with various classes / ids"
and then lists none of them, so every selector was read off a real render instead of guessed. The
stable hooks it ships are the ids `#page_wrapper`, `#inner_wrapper`, `#information-widgets`,
`#widgets-wrap`, `#services`, `#bookmarks`, `#footer`, and the classes `.service-card`,
`.service-title`, `.service-icon`, `.service-name`, `.service-description`, `.service-tags`,
`.k8s-status`, `.site-monitor-status`, `.services-group`, `.service-group-name`, `.services-list`,
`.bookmark-*`, `.information-widget-kubernetes`, `.information-widget-search`, `.widget-container`.
Everything else is a generated Tailwind utility class and is not safe to target. Two things that
cost time and are worth knowing next time:

- The page background comes from `#__next`, not from `body`. Setting `body` alone leaves the theme's
  slate-800 painted over it and the grid overlay invisible.
- The server-rendered HTML is placeholder content ("My First Group"). Real config only appears after
  hydration, so `curl` of `/` is misleading; read `/api/services` or a browser-rendered DOM.

Homepage has no header element — `title` only sets the document title — so the mockup's logo lockup
is synthesised from `#information-widgets::before` and `::after`. There is no clock: CSS cannot read
the time and `custom.js` stays empty as specified.

IBM Plex Mono is embedded as base64 woff2 at the bottom of `custom.css`, latin subset only, weights
300/400/500, about 30KB of font in a 53KB file. `scripts/embed-fonts.sh` regenerates that block and
is idempotent; it truncates at the fence line and rewrites below it. The whole ConfigMap is 59KB,
5.6% of the 1MB limit.

Verified in a browser: one 404 in the console and no CSS errors at all. The 404 is
`/api/kubernetes/status/ntfy/ntfy`, which is ticket 04's problem, not this one.

Two findings handed to later tickets:

- **Traefik is annotated but not discovered.** The `traefik-dashboard` IngressRoute in `kube-system`
  carries five `gethomepage.dev` annotations and no `gethomepage.dev/href`, so homepage skips it.
  `traefik: true` works; the annotation is incomplete. Ticket 04.
- **Service icons are fetched from `cdn.jsdelivr.net`.** The only host the page contacts besides
  itself. This is the same public-dependency-in-front-of-an-internal-dashboard problem that ruled
  out a webfont here, and it was not considered when icons were scoped. Homepage can serve icons
  from `/app/config/icons/` instead, which would need a chart change. Ticket 06 should decide.

Status moved to `ready-for-human` — the files are done and verified, but nothing is deployed until
ticket 03 wires up the role.
