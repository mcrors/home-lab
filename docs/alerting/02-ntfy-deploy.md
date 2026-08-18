# Task: Deploy Ntfy ✅ DONE (2026-08-18)

Deploy the Ntfy notification server in-cluster via Helm, following the same Ansible role pattern as Grafana and Alertmanager.

## Decisions

- **Namespace**: `ntfy`
- **Deploy method**: Helm (`binwiederhier/ntfy` chart from Artifact Hub — verify chart repo URL before implementing)
- **Persistence**: Longhorn PVC for SQLite message cache (small, ~1Gi)
- **Auth**: token-based. Token stored in Ansible Vault → K8s Secret → referenced via inline `values:` in Helm task (same pattern as Grafana admin password)
- **Topic**: `homelab-alerts` (single topic)
- **Upstream relay**: enabled (`upstream-base-url: https://ntfy.sh`) for iOS push via APNs. Alert content transits ntfy.sh infrastructure — acceptable for homelab.
- **Ingress**: Traefik IngressRoute at `ntfy.houli.eu`, TLS via `houli-eu-wildcard` cert. LAN-accessible (phone on WiFi uses web UI; push to phone via relay needs no inbound).
- **Node affinity**: prefer `node_size: small` (potato) or `node_size: medium` (pi ≤4GB), avoid `node_size: large` and `node_size: x-large`. Note: node relabeling is tracked separately in `node-relabeling.md` — use current `node_type` labels until that work is done.

## Implementation

1. Create `infra/roles/ntfy/` following the standard role structure:
   - `defaults/main.yaml` — chart version, namespace (`ntfy`), PVC name, secret name
   - `files/values.yaml` — Helm values (resources, affinity, ingress, persistence referencing existing PVC, upstream relay config)
   - `tasks/main.yaml` — create namespace, create Longhorn PVC, create K8s Secret (vault token in `stringData`), add Helm repo, install/upgrade chart with `values_files` + inline `values:` for PVC claim and secret reference

2. Add a play to `infra/playbooks/observability.yaml` with tag `ntfy`

3. Add `vault_ntfy_access_token` to the appropriate vault file (`infra/group_vars/k3s_cluster/vault.yaml`)

## Post-deploy: token bootstrapping (one-time)

The server starts with `auth-default-access: deny-all` — nothing can publish or subscribe until a user and token are created. Do this once after the pod is Running:

```bash
# Create an admin user (you'll be prompted for a password)
kubectl exec -n ntfy deploy/ntfy -- ntfy user add --role=admin admin

# Generate an access token for that user
kubectl exec -n ntfy deploy/ntfy -- ntfy token add admin
```

The second command prints a token like `tk_xxxxxxxxxxxxxxxxxxxxxxxxxx`. **Store it in Ansible Vault:**

```bash
# Edit the vault file
ansible-vault edit infra/group_vars/k3s_cluster/vault.yaml
# Add: vault_ntfy_access_token: "tk_xxxxxxxxxxxxxxxxxxxxxxxxxx"
```

This token is used by:
- **Ticket 04** (`alertmanager-ntfy-config.md`) — Alertmanager authenticates to the bridge with this token
- **Ticket 05** (`uptime-kuma-ntfy.md`) — Uptime Kuma notification config
- **iOS app** — subscribe to `homelab-alerts` topic using Bearer token auth

The token persists in the Longhorn PVC (`auth.db`), so it survives pod restarts. If you ever need to rotate it:
```bash
kubectl exec -n ntfy deploy/ntfy -- ntfy token remove admin <token>
kubectl exec -n ntfy deploy/ntfy -- ntfy token add admin
# Update vault_ntfy_access_token and re-run tickets 04 and 05
```

## Validation

- Pod is Running: `kubectl get pods -n ntfy`
- `curl -H "Authorization: Bearer <token>" https://ntfy.houli.eu/homelab-alerts/json` returns SSE stream
- Install Ntfy iOS app, subscribe to `homelab-alerts` topic with the Bearer token
- `curl -H "Authorization: Bearer <token>" -d "test" https://ntfy.houli.eu/homelab-alerts` → notification on phone

## Dependencies

None — can be implemented first.
