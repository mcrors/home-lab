# Alerting system

## Stack

| Component | Role | Namespace | Playbook tag |
|---|---|---|---|
| Prometheus | Scrapes metrics, evaluates alert rules | `monitoring` | `prometheus` |
| Alertmanager | Routes firing alerts to receivers | `monitoring` | `alertmanager` |
| ntfy | Self-hosted push notification server | `ntfy` | `ntfy` |
| ntfy-bridge (`alertmanager-ntfy`) | Forwards Alertmanager webhooks to ntfy | `ntfy` | `ntfy-bridge` |
| signal-bridge | Forwards ntfy messages to Signal | `ntfy` | `signal-bridge` |
| Uptime Kuma | Synthetic uptime monitors | `monitoring` | — (manual) |

Alert flow: Alertmanager → ntfy-bridge → ntfy → signal-bridge → Signal group → phone.

---

## Deploy

Run all alerting components:

```bash
ansible-playbook infra/playbooks/observability.yaml --tags ntfy
ansible-playbook infra/playbooks/observability.yaml --tags ntfy-bridge
ansible-playbook infra/playbooks/observability.yaml --tags alertmanager
ansible-playbook infra/playbooks/observability.yaml --tags signal-bridge
```

---

## ntfy token bootstrap

Run once after the ntfy pod is first deployed:

```bash
kubectl exec -n ntfy deploy/ntfy -- ntfy user add --role=admin admin
kubectl exec -n ntfy deploy/ntfy -- ntfy token add admin
```

Store the generated token in Ansible Vault as `vault_ntfy_access_token` in `infra/group_vars/all/vault.yaml`.

### Token rotation

```bash
kubectl exec -n ntfy deploy/ntfy -- ntfy token remove admin <old-token>
kubectl exec -n ntfy deploy/ntfy -- ntfy token add admin
```

Update `vault_ntfy_access_token` in vault, then re-run the ntfy-bridge and signal-bridge tags to update their Secrets.

---

## Signal bridge — device link

Run once on first setup, or after a lost PVC.

```bash
kubectl -n ntfy port-forward deploy/signal-cli 8080:8080
```

Open `http://localhost:8080/v1/qrcodelink?device_name=signal-bridge` in a browser. Scan the QR code on the iPhone (Signal → Settings → Linked Devices → Link New Device).

### Collect group IDs after linking

```bash
curl -s http://localhost:8080/v1/receive/<account>
curl -s http://localhost:8080/v1/groups/<account> | jq '.[] | {id, name}'
```

Store each group ID in Ansible Vault, then re-run the signal-bridge tag and restart the pod.

### Send a test message

```bash
curl -s -X POST \
  -H 'content-type: application/json' \
  -d '{"message":"test","number":"<account>","recipients":["<group-id>"]}' \
  http://localhost:8080/v2/send
```

---

## Signal bridge — upgrade

Signal-cli releases older than three months can stop working. Check monthly.

1. Snapshot the `signal-cli-data` PVC in Longhorn.
2. Update `signal_cli_image_tag` in `infra/roles/signal_bridge/defaults/main.yaml`.
3. Run Ansible: `ansible-playbook infra/playbooks/observability.yaml --tags signal-bridge`
4. Send a test message and confirm it arrives in the Signal group.

**Rollback:** revert `signal_cli_image_tag` and re-run. If the session is corrupted, restore the PVC snapshot and re-run.

---

## Uptime Kuma — ntfy setup

Manual configuration in the Uptime Kuma UI. Settings → Notifications → Add Notification:

- Type: **Ntfy**
- Server URL: `https://ntfy.houli.eu`
- Topic: `homelab-alerts`
- Auth: Bearer token (`vault_ntfy_access_token` value)
- Priority: `urgent`

Apply to all node monitors. Test by pausing a monitor and confirming the notification arrives.

---

## Test the full pipeline

Fire a synthetic alert through Alertmanager:

```bash
curl -X POST https://alertmanager.houli.eu/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning"},"annotations":{"summary":"Test alert"}}]'
```

Check each leg:
1. Alert appears in Alertmanager UI.
2. Message appears in ntfy: `curl -s -H "Authorization: Bearer <token>" "https://ntfy.houli.eu/homelab-alerts/json?poll=1"`
3. `kubectl -n ntfy logs deploy/signal-bridge` shows `result=ok`.
4. Message arrives in the Signal group on the phone.

---

## Alerts still to implement

| Alert | Description |
|---|---|
| `DeploymentReplicaMismatch` | Desired vs available replicas differ |
| `JobFailed` | Kubernetes Job exited non-zero |
| `BlackboxProbeFailed` | Synthetic probe down |
| `SSLCertExpiringSoon` | Certificate expires within 14 days |
| `TraefikHighErrorRate` | 5xx rate above threshold |
| `DNSResolutionFailed` | Internal DNS not resolving |
| `PrometheusTargetDown` | Scrape target unreachable |
| `PrometheusStorageFilling` | TSDB filling up |
| `SystemClockSkew` | NTP drift above threshold |
