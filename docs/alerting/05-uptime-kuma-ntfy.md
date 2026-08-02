# Task: Configure Uptime Kuma to Push to Ntfy

Wire up Uptime Kuma's node-down alerts to Ntfy. This is a manual step in the Uptime Kuma UI — no Ansible changes needed.

## Context

Uptime Kuma handles node-down / node-unreachable alerts independently of Prometheus. Prometheus can't reliably alert on its own scrape targets being unreachable, so Uptime Kuma acts as an independent watchdog.

## Steps

1. In Uptime Kuma UI, go to **Settings → Notifications → Add Notification**
2. Type: **Ntfy**
3. Server URL: `http://ntfy.ntfy.svc.cluster.local` (if Uptime Kuma is in-cluster) or `https://ntfy.houli.eu` (if it can't resolve cluster DNS — try internal first)
4. Topic: `homelab-alerts`
5. Auth: token (use `vault_ntfy_access_token` value)
6. Priority: set to `urgent` — node-down is always a critical alert
7. Apply the notification to all existing node monitors

## Validation

- Pause a monitor temporarily, confirm notification arrives on phone
- Resume monitor, confirm resolved notification arrives

## Dependencies

- `ntfy-deploy.md` complete
