Status: resolved
Blocked by: 01

# M1: write the Ansible role and playbook for the controller

## Context

Ansible installs the upstream chart. The role follows `infra/roles/alertmanager` exactly. This ticket writes the role and the playbook wiring. It deploys the controller only — no agent configuration yet.

See `docs/jenkins/jenkins-prd.md` sections 6 (Non-functional requirements) and 7 (Deployment).

## Scope

Create `infra/roles/jenkins/` with `tasks/main.yaml`, `defaults/main.yaml`, and `files/values.yaml`.

### `tasks/main.yaml`

Four tasks, in the order used by `infra/roles/alertmanager/tasks/main.yaml`:

1. `kubernetes.core.helm_repository` — name `jenkinsci`, url `https://charts.jenkins.io`
2. `kubernetes.core.helm` cache refresh against `kube-system`, `state: absent`, `update_repo_cache: true`
3. `kubernetes.core.k8s` — create the `{{ jenkins_namespace }}` Namespace
4. `kubernetes.core.helm` — install/upgrade `jenkins` from `jenkinsci/jenkins`, `chart_version: "{{ jenkins_chart_version }}"`, `create_namespace: false`, `wait: true`, values from `{{ role_path }}/files/values.yaml`

No PodSecurity namespace label is needed. Ticket 01 confirmed k3s admits a privileged pod with no policy change.

### `defaults/main.yaml`

```yaml
jenkins_namespace: jenkins
jenkins_chart_version: 5.9.54
jenkins_host: jenkins.houli.eu
```

### `files/values.yaml`

Controller settings:

- `controller.numExecutors: 0`
- `controller.jenkinsUrl: https://jenkins.houli.eu` — this clears the reverse proxy warning in `TODO.md`
- `controller.javaOpts: "-XX:MaxRAMPercentage=70.0"`
- `controller.resources`: request `500m` CPU and `1Gi` memory, limit `1536Mi` memory, **no CPU limit**
- `controller.nodeSelector` / affinity: required `node_type=pi`, preferred `node_size=medium`
- `controller.installPlugins`: keep the chart's four defaults and pin the additions needed later — `configuration-as-code`, `kubernetes`, `workflow-aggregator`, `git`, `github-branch-source`, `docker-workflow`, `credentials-binding`, `timestamper`, `build-timeout`
- `controller.initializeOnce: false` for now. Ticket 08 flips it.

Do not set the controller image tag. Ticket 01 confirmed the chart composes it from its own appVersion, giving `jenkins/jenkins:2.568.2-jdk21`.

Do not set a `strategy` value. The chart renders a **StatefulSet**, not a Deployment, so `strategy: Recreate` is not a valid field. A StatefulSet already stops the old pod before it starts the new one.

Ingress:

- `controller.ingress.enabled: true`, `apiVersion: networking.k8s.io/v1`, `ingressClassName: traefik`
- `hostName: jenkins.houli.eu`, TLS host the same
- annotations exactly as listed in PRD section 7 (Ingress annotations), including the six `gethomepage.dev/*` keys

Persistence:

- `persistence.enabled: true`, `storageClass: longhorn`, `size: 8Gi`, `accessMode: ReadWriteOnce`

Leave `agent:` at chart defaults in this ticket. Ticket 04 configures it.

### Playbook wiring

Create `infra/playbooks/ci.yaml` in the shape of the plays in `infra/playbooks/observability.yaml`:

- `hosts: localhost`, `connection: local`, `gather_facts: false`, `become: false`
- `vars: ansible_python_interpreter: "{{ ansible_playbook_python }}"`
- `vars_files: - ../vars/main.yaml`
- `roles: - jenkins`
- `tags: jenkins`

Import it from `infra/playbook.yaml` under the `ci` tag, after `observability`.

## Notes

- Do not run the playbook in this ticket. Ticket 03 deploys.
- Validate with `helm template` against the values file before finishing.

## Acceptance criteria

- `helm template jenkins jenkinsci/jenkins --version 5.9.54 -f infra/roles/jenkins/files/values.yaml` renders with no error.
- The rendered StatefulSet shows 0 executors, the pi affinity, and no CPU limit.
- The rendered Ingress shows the Traefik class, the TLS host, and all six homepage annotations.
- The rendered PVC shows `longhorn` and `8Gi`.
- `infra/playbook.yaml` imports `playbooks/ci.yaml` under the `ci` tag.
- No secret value appears in any file.

## Answer

Implemented 2026-09-13. Four files added, one edited. Nothing deployed.

| File | Change |
|---|---|
| `infra/roles/jenkins/tasks/main.yaml` | new, four tasks in the `alertmanager` order |
| `infra/roles/jenkins/defaults/main.yaml` | new |
| `infra/roles/jenkins/files/values.yaml` | new |
| `infra/playbooks/ci.yaml` | new, one localhost play tagged `jenkins` |
| `infra/playbook.yaml` | imports `playbooks/ci.yaml` under tag `ci`, between `observability` and `security` |

### Decisions taken while implementing

1. **`affinity` only, no `nodeSelector`.** The scope line reads "`controller.nodeSelector` / affinity". A nodeSelector cannot express a preference, so the whole rule is one `controller.affinity` block: required `node_type In [pi]`, preferred `node_size In [medium]` at weight 100. This mirrors `infra/roles/alertmanager/files/values.yaml`.

2. **Plugin pinning.** `controller.installPlugins` replaces the chart list rather than extending it, so the chart's four defaults are restated at the chart's own versions. `controller.installLatestPlugins` is left at the chart default `true`, so transitive dependencies still float. That is PRD section 5 known gap 4 and it closes when ticket 08 sets `initializeOnce: true`. Versions confirmed against `plugins.jenkins.io`; every added plugin declares a `requiredCore` at or below 2.568.2.

   | Plugin | Version | requiredCore |
   |---|---|---|
   | `kubernetes` | 4540.v612369217f87 | chart default |
   | `workflow-aggregator` | 608.v67378e9d3db_1 | chart default |
   | `git` | 5.10.1 | chart default |
   | `configuration-as-code` | 2117.vc05a_0b_e6b_f4e | chart default |
   | `github-branch-source` | 1983.vfa_27ed961853 | 2.541.1 |
   | `docker-workflow` | 653.v2f2c08eff0ec | 2.541.3 |
   | `credentials-binding` | 728.v902a_273b_8947 | 2.479.3 |
   | `timestamper` | 1.30 | 2.479.3 |
   | `build-timeout` | 1.41 | 2.541.3 |

3. **Blackbox probe annotations, added beyond the written scope.** `prometheus.io/probe: "true"` and `prometheus.io/probe-path: /login` are on the Ingress. See Finding E.

4. **TLS with no `secretName`.** Traefik serves its default certificate, matching 11 of the 13 Ingresses already in the cluster. The `houli-eu-wildcard` Secret exists only in the `ntfy` namespace and a Secret does not cross namespaces.

### Finding D — a CPU limit survives omission. Affects any future role that trims chart resources.

The first render carried `limits.cpu: 2000m` even though the values file set only `limits.memory`. Helm merges maps key by key, so omitting a key keeps the chart default at `values.yaml:128`. The acceptance criterion and PRD section 6 both require no CPU limit, so the key is nulled explicitly:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: null
    memory: 1536Mi
```

The re-render shows `{'limits': {'memory': '1536Mi'}, 'requests': {'cpu': '500m', 'memory': '1Gi'}}`.

### Finding E — the blackbox probe annotations had no owner. Affects ticket 07.

`infra/roles/prometheus/templates/prometheus.yml.j2` already carries a `blackbox-ingress` job that discovers probe targets with `role: ingress`. Its first relabel rule is an `action: keep` on `prometheus.io/probe`, so an Ingress without that annotation is dropped silently. The job's comment at line 135 already names this service: "plex needs /web/index.html, jenkins will need /login".

Neither ticket owned the Ingress half. PRD section 7 lists six annotations and `prometheus.io/probe` is not among them, so this ticket's acceptance criteria never asked for it. Ticket 07 scope item 1 then says the probe is "already configured ... No change expected", which is true of the Prometheus side and false of the Ingress side. Ticket 07 would have opened, found no probe, and come back here.

Both annotations are now on the Ingress:

```yaml
prometheus.io/probe: "true"
prometheus.io/probe-path: /login
```

`/login` rather than `/` because PRD section 6 denies anonymous read, so `/` may answer 403. The `http_2xx` module sets `follow_redirects: true`, so a 302 to the login page would pass, but a bare 403 would not. `/login` answers 200 to an unauthenticated client under either authorization strategy. Which one Jenkins does cannot be checked until ticket 03 deploys, and `/login` makes the answer irrelevant.

The hyphen in `probe-path` matches the plex Ingress, the only other one carrying the override. Prometheus rewrites every non-alphanumeric character in an annotation name to `_` when it builds the meta label, so `probe-path` and `probe_path` both reach the rule that reads `__meta_kubernetes_ingress_annotation_prometheus_io_probe_path`.

`prometheus.io/probe-module` is not set. The relabel chain defaults `__param_module` to `http_2xx`, and `http_2xx` is the only module defined in `infra/roles/blackbox_exporter/files/values.yaml`.

Replaying the relabel chain against the rendered Ingress gives `__param_target=https://jenkins.houli.eu/login`, `__param_module=http_2xx`, `instance=https://jenkins.houli.eu`.

### Acceptance criteria

| Criterion | Result |
|---|---|
| `helm template` renders with no error | pass, exit 0, no stderr |
| StatefulSet shows 0 executors | pass, JCasC ConfigMap `jenkins.numExecutors: 0` |
| StatefulSet shows the pi affinity | pass, required `node_type In [pi]`, preferred `node_size In [medium]` |
| StatefulSet shows no CPU limit | pass after Finding D |
| Ingress shows the Traefik class | pass, `ingressClassName: traefik` |
| Ingress shows the TLS host | pass, `tls[0].hosts == [jenkins.houli.eu]` |
| Ingress shows all six homepage annotations | pass, five `gethomepage.dev/*` plus `traefik.ingress.kubernetes.io/router.tls` |
| Ingress carries the blackbox probe annotations | pass, beyond written scope, see Finding E |
| PVC shows `longhorn` and `8Gi` | pass |
| `infra/playbook.yaml` imports `ci.yaml` under tag `ci` | pass, `--list-tags` shows play #28 `TAGS: [jenkins,ci]` |
| No secret value in any file | pass |

`ansible-playbook playbook.yaml --syntax-check` passes.

### Confirmed incidentally

The rendered controller image is `docker.io/jenkins/jenkins:2.568.2-jdk21`, matching ticket 01. The chart renders a StatefulSet with no `strategy` field, confirming Finding C. A `Secret jenkins` still renders because `controller.admin.existingSecret` is empty; ticket 05 removes it.

### Left for later tickets

`jenkins_host` in `defaults/main.yaml` is unused. `files/values.yaml` is a static file, so the hostname is written literally in three places inside it. The ticket specified both, so both are here. If a second environment ever appears, the values file becomes a template and the default starts doing work.
