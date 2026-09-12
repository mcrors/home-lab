Status: ready-for-agent
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
