# Task: Deploy Ntfy-Alertmanager Bridge

Deploy a small adapter that translates Alertmanager's webhook JSON payload into Ntfy's HTTP format, and maps severity labels to Ntfy priorities.

## Why

Alertmanager's webhook receiver POSTs a fixed JSON structure. Ntfy's API expects plain text in the body with metadata in HTTP headers. Without a bridge, Ntfy displays raw JSON blobs on the phone.

## Decisions

- **Namespace**: `ntfy` (same as Ntfy server)
- **Deploy method**: static Kubernetes manifest (Deployment + Service) — no Helm chart exists for this. Apply via `kubernetes.core.k8s` in a new Ansible role.
- **Image**: find a suitable community bridge image (e.g. search `alertmanager ntfy` on Docker Hub / GitHub). Verify it supports priority mapping via severity labels before committing to one.
- **Node affinity**: same as Ntfy — prefer `node_size: small` or `node_size: medium`, avoid `large` and `x-large`
- **Internal address**: `http://ntfy-bridge.ntfy.svc.cluster.local:<port>` — Alertmanager calls this, bridge forwards to `http://ntfy.ntfy.svc.cluster.local`

## Priority mapping

| Alertmanager severity | Ntfy priority |
|-----------------------|---------------|
| `critical`            | `urgent` (5)  |
| `warning`             | `default` (3) |
| `info`                | `low` (2)     |

Configure this mapping in the bridge (env vars or config file depending on chosen image).

## Implementation

1. Create `infra/roles/ntfy_bridge/`:
   - `defaults/main.yaml` — image, namespace, port
   - `files/ntfy-bridge.yaml` — Deployment + Service manifest
   - `tasks/main.yaml` — apply manifest via `kubernetes.core.k8s`

2. Add a play to `infra/playbooks/observability.yaml` with tag `ntfy-bridge`

## Validation

- Bridge pod is Running in `ntfy` namespace
- `curl -X POST http://ntfy-bridge.ntfy.svc.cluster.local:<port> -d '<alertmanager test payload>'` → notification appears on phone with correct priority

## Dependencies

- `ntfy-deploy.md` must be complete (bridge needs Ntfy running to forward to)
