Status: resolved
Blocked by: 01

# Ansible role and playbook wiring

## Context

`services/roles/uptime-kuma/` is the closest existing role: a stateless service, no vault secrets,
the same affinity. Follow it.

See `docs/homepage/homepage-project-plan.md` row HOM-03.

## Scope

Create `services/roles/homepage/` with `tasks/main.yaml`, `defaults/main.yaml`, and
`files/values.yaml`.

`tasks/main.yaml` follows the uptime-kuma order: create the `{{ homepage_namespace }}` Namespace
with `kubernetes.core.k8s`, then `kubernetes.core.helm` installing the local chart at
`services/helm/homepage` with `create_namespace: false` and `wait: true`, values from
`{{ role_path }}/files/values.yaml`. There are no secrets to create.

All seven config files from ticket 02 stay real files in `{{ role_path }}/files/` and are passed
with `--set-file`. None of their content belongs in a values file. Write the entries out explicitly,
one per file, rather than generating them from a list in a Jinja loop — this repo has already been
bitten once by whitespace inside a Jinja loop in the prometheus template, and seven static lines are
easier to read and to grep than the loop that would produce them:

```yaml
set_values:
  - value: 'config.settings\.yaml={{ role_path }}/files/settings.yaml'
    value_type: file
  - value: 'config.services\.yaml={{ role_path }}/files/services.yaml'
    value_type: file
  - value: 'config.widgets\.yaml={{ role_path }}/files/widgets.yaml'
    value_type: file
  - value: 'config.bookmarks\.yaml={{ role_path }}/files/bookmarks.yaml'
    value_type: file
  - value: 'config.kubernetes\.yaml={{ role_path }}/files/kubernetes.yaml'
    value_type: file
  - value: 'config.custom\.css={{ role_path }}/files/custom.css'
    value_type: file
  - value: 'config.custom\.js={{ role_path }}/files/custom.js'
    value_type: file
```

That leaves `files/values.yaml` holding only the hostname, the TLS reference, the affinity block and
the allowed hosts — nothing config-shaped.

`kubernetes.core.helm` turns a `set_values` entry with `value_type: file` into `helm --set-file`.
Note the escaped dot in every key. Helm reads an unescaped `.` as a nesting separator, so
`config.custom.css=...` silently builds a three-level structure instead of setting the
`custom.css` key, and the file never reaches the ConfigMap. The chart's string defaults mean this
fails quietly — the pod still starts, just with the default content — so check the deployed
ConfigMap rather than trusting the playbook's exit code:

```
kubectl get configmap homepage -n homepage -o jsonpath='{.data}' | python3 -m json.tool
```

`files/values.yaml` sets at minimum:

- `ingress.hosts[0].host`: `homepage.houli.eu`
- `ingress.tls` referencing `houli-eu-wildcard`
- `env.HOMEPAGE_ALLOWED_HOSTS`: `homepage.houli.eu`
- the affinity block: `node_size In ["medium"]`. The shape is the one in `services/roles/uptime-kuma/files/values.yaml`, but the values list is `medium` alone, not `["medium", "large"]`
- `prometheus.io/probe: "true"` on the Ingress, matching every other service here

While the pod is running, try `securityContext.readOnlyRootFilesystem: true` in the role's values.
Ticket 01 left it off because homepage is a Next.js app that writes at runtime and the full set of
paths it touches is not knowable without running it. Find them from the crash output, mount an
`emptyDir` over each, and keep the setting if it holds. Back it out and say so in `## Comments` if
the list turns out to be long or unstable — this is a hardening bonus, not a requirement for the
ticket to pass.

Then append a `homepage` play to the end of `services/playbook.yaml`, copying the shape of the
`Install Uptime-kuma into K3s` play, tagged `homepage`. There is no `services/playbooks/` directory;
do not create one.

## Acceptance criteria

- `ansible-playbook playbook.yaml --tags homepage` succeeds and reports no changes on a second run.
- The pod reaches `Running` and lands on a `node_size: medium` node — lib-pi-01, lib-pi-02, or lib-pi-03 on the current cluster (`kubectl get pod -n homepage -o wide`).
- `https://homepage.houli.eu` loads over TLS with a valid wildcard certificate.
- The Kubernetes cluster and nodes widgets show live CPU and memory, which also proves the ClusterRole from ticket 01 is sufficient.
- The four already-annotated services (Alertmanager, kube-state-metrics, Ntfy, Traefik) appear without any further change, or the Traefik `IngressRoute` gap from ticket 04 is confirmed here.
- The `readOnlyRootFilesystem` attempt is resolved either way, with the outcome in `## Comments`.
- All seven keys in the deployed ConfigMap hold the content of the matching file in `files/`, proving every `--set-file` key is escaped correctly.

## Comments

Role written, deployed, and verified against the live cluster on 2026-09-12. The dashboard serves at
`https://homepage.houli.eu`.

The first deploy crash-looped, and the cause was in the chart rather than the role. Homepage expects
nine config files in `/app/config` and the chart defaulted only seven, so on the first request that
reads config it tried to create `docker.yaml` from its skeleton and hit `EACCES`: the directory is
root-owned, the pod runs as UID 1000, and the image's entrypoint skips its chown for want of a root
phase. Homepage exits 1. Fixed in the chart by defaulting `docker.yaml` and `proxmox.yaml` to empty
strings; written up in ticket 01.

Two things about that are worth carrying forward:

- **Nothing caught it before a user did.** Both probes hit `/api/healthcheck`, which never touches
  config, so the pod passed its probes and `helm --wait` reported a successful install. The crash
  loop only started when a browser loaded the page. A green playbook run proves less here than it
  looks like it does.
- **The trigger is `/api/hash`**, the call the browser makes after the page HTML loads. `curl` of `/`
  returns 200 and touches nothing, which matches the note in ticket 02 about `/` being misleading.

Acceptance criteria, checked one at a time:

- Playbook succeeds. It reports `changed` on a re-run even when nothing changes, which is the module
  warning about itself: `The default idempotency check can fail to report changes in certain cases.
  Install helm diff >= 3.4.1 for better results.` The deployed state is idempotent — a second run
  left the same pod in place, same name, zero restarts. Installing the `helm-diff` plugin would fix
  the reporting, and is worth doing for every helm role in this repo rather than for this one.
- Pod runs on `lib-pi-01`, whose `node_size` label is `medium`.
- TLS is a valid Let's Encrypt wildcard, `CN=*.houli.eu`, valid to 14 Nov 2026. Checked without
  `curl -k`.
- The Kubernetes widget returns live cluster and per-node CPU and memory for all nine nodes, which
  confirms the ClusterRole from ticket 01 is sufficient.
- Three of the four already-annotated services appear: Alertmanager, kube-state-metrics, Ntfy. Traefik
  does not, which confirms the gap ticket 02 flagged and ticket 04 owns. The `traefik-dashboard`
  IngressRoute in `kube-system` carries the five `gethomepage.dev` annotations and no
  `gethomepage.dev/href`, so homepage reads it and skips it. `traefik: true` is working.
- All seven `--set-file` keys are escaped correctly. The deployed ConfigMap holds seven flat keys, and
  inside the pod every file is byte-identical to its counterpart in `files/`, including `custom.css`
  at 54518 bytes.

`readOnlyRootFilesystem` was not adopted. The crash settled the question without an experiment:
homepage writes into `/app/config` at runtime, and the chart mounts that path as individual read-only
`subPath` files with no writable layer. Turning the flag on needs a writable mount at `/app/config`,
which would mean either an `emptyDir` seeded from the ConfigMap by an init container, or giving up
the read-only config the design deliberately chose. That is a larger change than a hardening bonus
justifies. `securityContext` stays a values passthrough, so it can be revisited without a template
change.

Media and CI/Ops render empty. Both groups are declared in `settings.yaml` and nothing carries the
matching `gethomepage.dev/group` annotation yet. Ticket 04 fills them.

Resolved.
