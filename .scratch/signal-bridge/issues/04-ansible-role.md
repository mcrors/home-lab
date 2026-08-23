Status: ready-for-agent

# M2: write Ansible role for signal-bridge K8s objects

## Context

The signal-bridge deploys to the existing `ntfy` namespace on the k3s cluster. Ansible applies plain manifests — no Helm chart. This ticket writes the Ansible role that creates all required K8s objects.

See `docs/alerting/signal-bridge-prd.md` sections 4 (Architecture), 6 (Non-functional requirements), and 7 (Deployment).

## Scope

Create an Ansible role at `infra/roles/signal_bridge/`. The role deploys to the `ntfy` namespace.

### K8s objects to create

| Object | Name | Notes |
|---|---|---|
| Deployment | `signal-cli` | Runs the signal daemon |
| Deployment | `signal-bridge` | Runs the ntfy subscriber and forward.sh |
| Service | `signal-cli` | ClusterIP, port 8080 |
| PersistentVolumeClaim | `signal-cli-data` | Longhorn, 1 GiB, Retain |
| Secret | `signal-bridge-config` | Rendered from Ansible template |
| NetworkPolicy | `signal-cli-ingress` | Ingress to signal-cli from signal-bridge pods only |

### `signal-cli` Deployment

- Image: `bbernhard/signal-cli-rest-api:latest` (pin to a specific tag once M0 confirms the version)
- Env: `MODE=json-rpc`
- `nodeSelector: node_size: x-large`
- `strategy: Recreate`
- 1 replica
- PVC `signal-cli-data` mounted at `/home/.local/share/signal-cli`
- No hostPort, no Ingress
- Memory limit: 768 MiB
- Memory request: 512 MiB
- CPU: no limit, request 100m

### `signal-bridge` Deployment

- Image: `ghcr.io/<user>/signal-bridge:<tag>` (exact SHA tag, set as a role variable)
- 1 replica
- Secret `signal-bridge-config` mounted at `/etc/ntfy/client.yml` (the `client.yml` key)
- Env vars from the same Secret: `SIGNAL_ACCOUNT`, `GROUP_HOMELAB_ALERTS`
- No PVC, no hostPort, no Ingress
- Memory limit: 64 MiB
- Memory request: 32 MiB

### PVC

- Storage class: `longhorn`
- Access mode: `ReadWriteOnce`
- Size: `1Gi`
- Reclaim policy: `Retain`

### Secret

Rendered from a Jinja2 template. The template lives in the role at `templates/client.yml.j2`.

The Secret holds three keys:
- `client.yml` — rendered ntfy subscriber config
- `SIGNAL_ACCOUNT` — the Signal account phone number
- `GROUP_HOMELAB_ALERTS` — the Signal group ID for the homelab-alerts topic

`client.yml.j2` template:

```yaml
default-host: https://ntfy.houli.eu
auth:
  token: {{ signal_bridge_ntfy_token }}
subscribe:
  - topic: homelab-alerts
    command: '/opt/forward.sh "$GROUP_HOMELAB_ALERTS"'
```

No `if:` priority filter. Forward all priorities.

### NetworkPolicy

Allow ingress to the `signal-cli` pods on port 3000 only from pods with the label `app: signal-bridge`. Deny all other ingress to port 3000.

### Vault variables required

The role reads these from Ansible Vault:

- `signal_bridge_ntfy_token` — ntfy auth token for the subscriber
- `signal_account_number` — Signal phone number for the linked device
- `signal_group_homelab_alerts` — Signal group ID (populated in ticket 05 after device link)

### Playbook wiring

Add the role to the appropriate playbook so it runs against the NUC node (or the control-plane node that manages the ntfy namespace). Follow the pattern used by the existing ntfy role.

## Acceptance criteria

- `kubectl get all -n ntfy` shows both Deployments, the Service, and the PVC after running the role.
- The Secret exists and holds the three expected keys.
- The NetworkPolicy is applied.
- Running the role a second time is a no-op (idempotent).
- No secret value appears in git (templates only, no rendered output).
