Status: ready-for-agent
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
