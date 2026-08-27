Status: ready-for-agent
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
