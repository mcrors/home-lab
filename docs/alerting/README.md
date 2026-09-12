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

## Alert rules

`alerts-to-create.md` is the canonical backlog. Do not duplicate its status here.

Rules live at `infra/roles/prometheus/files/alerts.yaml` and deploy to
`/mnt/prometheus/config/rules/alerts.yml` on lib-pi-06. Committed does not mean deployed: the
prometheus role is run by hand, and the two files sat four months apart until 2026-09-05. Check
before assuming a rule is live:

```bash
ssh lib-pi-06 'grep -E "^\s+- alert:" /mnt/prometheus/config/rules/alerts.yml'
```

Deploy with `ansible-playbook infra/playbooks/observability.yaml --tags prometheus`. The role has no
reload handler; the `docker-compose up --force-recreate -d` at the end of `tasks/main.yaml` picks up
config changes. That command is not idempotent, so **every run of this tag restarts Prometheus**
whether or not anything changed. Restart takes under 20 seconds and the TSDB is on a persistent LVM
volume, so this is noise rather than risk.

---

## Silence before a planned reboot

`NodeRebooted` fires on any node with an uptime under 5 minutes, and the Alertmanager route sends
every severity to ntfy, so an unsilenced reboot reaches Signal. There is no maintenance-window
mechanism: a silence is what marks a reboot as planned. Set one before rebooting a node by hand or
running a playbook that reboots nodes.

Add the silence in the Alertmanager UI at `https://alertmanager.houli.eu`, matching
`alertname="NodeRebooted"` and the `instance` you are about to reboot, or match on `alertname`
alone when a playbook will cycle several nodes. Keep the duration short; the alert clears on its
own once uptime passes 5 minutes.

Rebooting 2 or more nodes inside a 10 minute window also fires `MultiNodeRebootWindow` at critical
severity, which is deliberately hard to miss. An inhibit rule keyed on `cluster` stops the
per-node `NodeRebooted` notifications piling up underneath it. Silence that alertname too if you
are intentionally cycling the fleet.

---

## Blackbox probe targets

Two jobs feed `BlackboxProbeFailed`. A target belongs to exactly one of them.

| Job | Source | Covers | Targets |
|---|---|---|---|
| `blackbox-http` | Static list in `prometheus.yml.j2` | Anything with no Kubernetes Ingress: `prometheus`, `omv`, `traefik` | 3 |
| `blackbox-ingress` | Kubernetes service discovery, `role: ingress` | Every ingress carrying the opt-in annotation | 12 |

`traefik.houli.eu` stays static because it is a Traefik `IngressRoute` CRD, and `role: ingress`
only sees standard `networking.k8s.io/v1` Ingress objects.

Two alerts guard against these lists going empty, `BlackboxIngressDiscoveryEmpty` and
`BlackboxStaticTargetsEmpty`. Every other probe alert fires on a failed probe; if a job has no
targets there is nothing to fail, and monitoring stops silently while looking healthy. Both use
`absent()`. Do not rewrite them as `count(...) == 0`, which cannot fire: `count()` over an empty
vector returns an empty vector, so the comparison never evaluates.

Discovery authenticates to the API server with the `prometheus-scraper` token and needs
`list`/`watch` on `networking.k8s.io/ingresses`, granted in `infra/roles/prometheus_scraper/`.

### Opting an ingress in

Add annotations to the ingress. The probe starts within a minute, no Prometheus change needed.

| Annotation | Required | Purpose |
|---|---|---|
| `prometheus.io/probe` | yes | `"true"` to be probed. Must be a quoted string. |
| `prometheus.io/probe-path` | no | Probe a path other than the one the Ingress declares |
| `prometheus.io/probe-module` | no | Blackbox module other than `http_2xx` |

`prometheus.io/probe-path` exists because some services do not return 2xx at their ingress path.
Plex answers 401 at `/` and 200 at `/web/index.html`. Jenkins will need `/login`.

### Debugging discovery

The Service Discovery page at `https://prometheus.houli.eu/service-discovery` shows every discovered
candidate with its raw `__meta_*` labels and what they became after relabelling. Annotation keys are
mangled: every character outside `[a-zA-Z0-9_]` becomes an underscore, so `prometheus.io/probe-path`
arrives as `__meta_kubernetes_ingress_annotation_prometheus_io_probe_path`.

Zero scraped targets is ambiguous on its own. This separates "discovery found nothing" from
"discovery worked and the filter dropped everything":

```promql
prometheus_sd_discovered_targets{config="blackbox-ingress"}
```

Note the namespace label is `__meta_kubernetes_namespace`, without the `ingress` infix that the
other ingress metadata labels carry.

