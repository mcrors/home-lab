# Task: Configure Alertmanager to Route Alerts to Ntfy ✅ DONE (2026-08-20)

Update the Alertmanager Helm values to replace the current `null` receiver with a live ntfy receiver via the bridge, add severity-based routing, and add inhibit rules.

## Changes to `infra/roles/alertmanager/files/values.yaml`

### Receiver

Replace `receiver: 'null'` with a webhook receiver pointing at the bridge:

```yaml
receivers:
  - name: 'ntfy'
    webhook_configs:
      - url: 'http://ntfy-bridge.ntfy.svc.cluster.local:<port>/alert'
        send_resolved: true
        http_config:
          authorization:
            type: Bearer
            credentials_file: /etc/alertmanager/ntfy-token  # or pass via secret ref
```

Note: confirm the exact auth mechanism supported by the chosen bridge image (may be URL-embedded token rather than Authorization header).

### Route

```yaml
route:
  receiver: 'ntfy'
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers:
        - severity="critical"
      receiver: 'ntfy'
      repeat_interval: 1h
```

All severities (critical, warning, info) go to ntfy. Critical alerts repeat every 1h if still firing; everything else repeats every 4h.

### Inhibit rules

```yaml
inhibit_rules:
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity="warning"
    equal:
      - alertname
      - instance
```

Suppresses the warning-tier alert when a critical fires for the same `alertname` and `instance`. Prevents double-notification for alerts with two severity tiers (HighCPUUsage, HostHardwareTemp, SSLCertExpiringSoon).

## Secret handling

The Ntfy access token does not go in `values.yaml`. Pass it via inline `values:` in `infra/roles/alertmanager/tasks/main.yaml` (same pattern as Grafana), pulling from `vault_ntfy_access_token`.

Alternatively, if the bridge handles auth internally (token configured on the bridge side), no token is needed in Alertmanager config at all — confirm when bridge image is chosen.

## Validation

- Prometheus fires a test alert (or wait for a real one)
- Alertmanager UI shows alert routed to `ntfy` receiver
- Notification appears on phone
- Trigger both warning and critical for the same alertname on the same instance — confirm only one notification received (inhibit rule working)

## Dependencies

- `ntfy-deploy.md` complete
- `ntfy-bridge-deploy.md` complete

## Notes

- No token needed in Alertmanager config. Alertmanager calls the bridge over plain cluster-internal HTTP with no auth — the bridge owns the ntfy token and handles auth to ntfy itself. The secret handling section above is superseded.
- Pipeline confirmed working end-to-end: Alertmanager → bridge → ntfy. Messages appear in ntfy with correct topic and priority. Viewing the topic in the browser requires logging into the ntfy web UI (admin credentials) since `auth-default-access: deny-all`.
