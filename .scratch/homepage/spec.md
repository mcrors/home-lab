Status: ready-for-agent

# Homepage dashboard

See `docs/homepage/homepage-project-plan.md` for the full plan and
`docs/homepage/homelab-dashboard.html` for the visual mockup the custom CSS targets.

## Decisions recorded outside the plan

- Write a custom Helm chart at `services/helm/homepage/`. No community chart is maintained well enough to depend on. `services/helm/prowlarr` is the reference pattern.
- The role lives in `services/`, not `infra/`. Homepage is a user-facing service, and it needs no vault secrets.
- Scheduling is `nodeAffinity` on `node_size In ["medium"]` — lib-pi-01/02/03. Deliberately narrower than the `["medium", "large"]` that `services/roles/uptime-kuma` uses: lib-pi-05 is the only `large` node and is kept for workloads that need the headroom. No `nodeSelector`: in this repo that key is reserved for `longhorn-storage: "true"`, which a stateless Deployment does not need.
- No persistence. All configuration lives in a ConfigMap in the chart, so a config change is a `helm upgrade` and the pod is disposable.
- In-cluster services are discovered from `gethomepage.dev/*` Ingress annotations. Only off-cluster targets are hardcoded into `services.yaml`.
- The annotation form is the one already in the repo: five keys, icon name without a `.png` extension, and no `href` — Homepage derives the link from the Ingress host. Alertmanager, kube-state-metrics, Ntfy, and Traefik already carry it.
- `services/` has no `playbooks/` directory. Every play is written inline in `services/playbook.yaml`. The original plan assumed a separate playbook file; it is wrong.
- Pi-hole is not in the cluster yet. It is out of scope here and gets annotated by whichever project brings it in.
- Icons are audited as their own ticket after the dashboard is live. The names in the plan are guesses at the icon pack's spelling, and a missing icon degrades to a text placeholder rather than failing, so it needs a deliberate look.
- Config file content is a `config:` map in values, keyed by filename, and the Deployment builds its `subPath` mounts by ranging over that same map so the two cannot drift. Large files are never pasted into a values file: they stay real files and reach the chart through `helm --set-file`, which `kubernetes.core.helm` exposes as a `set_values` entry with `value_type: file`. Filename keys contain a dot, which must be escaped as `config.custom\.css` or Helm treats it as nesting and the file silently goes to the wrong place. All seven Homepage config files are handled this way, not just the stylesheet.
- Config is never authored as native YAML in a values file for the chart to serialise. Go templating sorts map keys alphabetically, and the key order of the `layout` block in `settings.yaml` sets the group display order on the page, so serialising would silently re-sort the dashboard. `--set-file` copies the file verbatim and preserves it.
- Homepage's `HOMEPAGE_ALLOWED_HOSTS` host check is kept rather than disabled with `*`. It blocks DNS rebinding, where a domain an attacker controls resolves to an internal IP so that a browser already inside the network reads internal data. A LAN-only deployment is the case this defends, not an exception to it. The chart adds the pod IP itself, because the kubelet probes the pod IP directly and homepage answers 400 to any host not on the list.
- The image is pinned through `appVersion`, currently `v2.3.0`, matching how the Prowlarr chart pins. Never `latest`: with `pullPolicy: IfNotPresent` a node that has already pulled it keeps serving the old image, and the running version appears nowhere in git.
- This effort runs before the Jenkins effort. `.scratch/jenkins/issues/07-monitoring-and-homepage.md` depends on the dashboard existing, and it owns the Jenkins annotation row.

## Issues

| # | Title | Blocked by |
|---|-------|------------|
| 01 | Scaffold the Helm chart | — |
| 02 | Write the ConfigMap content | 01 |
| 03 | Ansible role and playbook wiring | 01 |
| 04 | Annotate the remaining service Ingresses | 03 |
| 06 | Audit and fix every service icon | 04 |
| 05 | Per-service live-data widgets | 06 |

Ticket 06 is the last step before the dashboard counts as done. Ticket 05 is `needs-triage`, parked
behind a look at the finished page; it may end as `wontfix`.
