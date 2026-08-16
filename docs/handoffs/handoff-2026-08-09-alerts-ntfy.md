# Handoff — 2026-08-09

## Project

Home lab Kubernetes cluster (`mcrors/home-lab`). We've been working through a planned alerting + notification stack for the cluster. The work is tracked as numbered tickets in `docs/alerting/`.

## What's been done this session

### Skills setup
- Ran `/setup-matt-pocock-skills` — created `CLAUDE.md`, `docs/agents/issue-tracker.md` (local markdown), `docs/agents/triage-labels.md`, `docs/agents/domain.md`.

### Grilling session (`/grill-with-docs`)
- Worked through all decisions for the Ntfy notification stack. Full decisions are captured in the tickets at `docs/alerting/02–05`.
- Key decisions: token-based auth, single `homelab-alerts` topic, ntfy-alertmanager bridge for payload translation, priority mapping (critical=urgent, warning=default, info=low), all severities routed, repeat_interval 4h / 1h for critical, inhibit_rules to suppress warning when critical fires for same instance.

### Ticket 01 — Node relabeling (`docs/alerting/01-node-relabeling.md`) ✅ DONE
- Created `infra/roles/node_labels/tasks/main.yaml` — sets `node_type` (fixing server node gap) and `node_size` (small/medium/large/x-large) on all `k3s_cluster` nodes.
- Wired into `infra/playbooks/k3s.yaml` with tag `node_labels`.
- Ran successfully. All 9 nodes now labeled. Verified with `kubectl get nodes`.

### Ticket 02 — Ntfy deploy (`docs/alerting/02-ntfy-deploy.md`) — READY TO RUN
- Role fully written at `infra/roles/ntfy/` (static Kubernetes manifests, not Helm — chart repos were unreachable).
- Manifests: Namespace, Longhorn PVC (2Gi, `reclaimPolicy: Retain`), ConfigMap (server.yml), Deployment, Service, Ingress.
- Config: `auth-default-access: deny-all`, upstream relay to ntfy.sh enabled, affinity prefers `node_size=small/medium`.
- Wired into `infra/playbooks/observability.yaml` with tag `ntfy`.
- **Not yet run** — user was off home network at end of session.

## Immediate next step

Run the ntfy deployment (requires home network access):

```bash
cd infra
workon ansible   # Python virtualenv for Ansible — venvs at ~/venvs/ansible/
ansible-playbook playbooks/observability.yaml -i inventory.yaml --tags ntfy
```

Then do the one-time token bootstrapping — full steps in `docs/alerting/02-ntfy-deploy.md` under "Post-deploy: token bootstrapping". Summary:

```bash
kubectl exec -n ntfy deploy/ntfy -- ntfy user add --role=admin admin
kubectl exec -n ntfy deploy/ntfy -- ntfy token add admin
# Store printed token in Ansible Vault as vault_ntfy_access_token
```

## Remaining tickets

| # | File | Status | Notes |
|---|------|--------|-------|
| 03 | `docs/alerting/03-ntfy-bridge-deploy.md` | Not started | Static manifest. Helm search found bridge charts on Artifact Hub — worth checking `helm search hub ntfy` for a bridge chart before writing manifests. |
| 04 | `docs/alerting/04-alertmanager-ntfy-config.md` | Not started | Update Alertmanager values.yaml: ntfy receiver, sub-routes, inhibit_rules. Token from Vault goes in inline `values:` in the Ansible task. |
| 05 | `docs/alerting/05-uptime-kuma-ntfy.md` | Not started | Manual UI step in Uptime Kuma. Can do in parallel with 03–04 once ntfy is up. |
| 06 | `docs/alerting/06-workload-affinity-audit.md` | Not started | Update existing workload affinities to use `node_size` labels. Independent of ntfy work. |
| 07 | `docs/alerting/07-node-labels-refactor.md` | Not started | Tech debt — move `memory` + `iscsi_initiator` labeling from `k3s/worker` task into `node_labels` role. |

## Key infrastructure context

- **Prometheus**: external, on `lib-pi-06` (not in k3s), runs via Docker Compose
- **Alertmanager**: in-cluster, `alertmanager` namespace, currently `receiver: 'null'` (alerts fire but go nowhere)
- **Ansible**: virtualenv at `~/venvs/ansible/`, activate with `workon ansible`, run from `infra/` directory with `-i inventory.yaml`
- **Secrets**: Ansible Vault, password file at `~/.ansible/vault_pass.txt`, vault files at `infra/group_vars/*/vault.yaml`
- **Ingress**: Traefik, wildcard cert `houli-eu-wildcard`, pattern: standard Kubernetes Ingress with `traefik.ingress.kubernetes.io/router.tls: "true"` annotation
- **Node labels**: `node_type` (potato/pi/nuc) and `node_size` (small/medium/large/x-large) — both set on all cluster nodes

## Suggested skills

- `/implement` — for writing the bridge manifests (ticket 03) and Alertmanager config changes (ticket 04)
- `/code-review` — run after each ticket's implementation before deploying
- `/triage` — if new issues surface during the alerting work
