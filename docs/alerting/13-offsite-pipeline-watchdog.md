# Task: Off-site Watchdog for the Alerting Pipeline

Status: not started. Split out of `12-dead-mans-switch.md` on 2026-09-12, which built the
in-house half.

## The gap this closes

Ticket 12 delivered a daily heartbeat and a proactive signal-cli staleness alert. Both travel the
normal pipeline to Signal, which leaves two things uncovered.

**Absence detection is a human job.** The heartbeat only works if someone notices a message that
did not arrive. That is the signal people are worst at.

**Signal is the only route to the phone.** Every alert path runs through signal-cli, so a
signal-cli failure cannot report itself. The staleness alert mitigates this by firing early, while
signal-cli still works, but it does nothing for a sudden failure. `forward.sh` logs `result=error`
and exits non-zero on a failed send, so the failure is observable inside the cluster with no way
out of it.

**Nothing survives total cluster loss.** The generator runs on lib-pi-06, outside k3s, but every
delivery hop is in-cluster.

## Shape

A ping service such as healthchecks.io, which alerts when pings stop rather than when they arrive.
A timer on lib-pi-06 runs every 15 minutes, checks that Prometheus and Alertmanager answer their
APIs, publishes a token to a `homelab-heartbeat` ntfy topic and reads it back, then pings the
service only if all of that passes. When pings stop, the service emails from off-site.

`signal-bridge` subscribes only to `homelab-alerts` (`client.yml.j2`), so a separate heartbeat
topic reaches ntfy without waking the Signal group. No second bridge deployment is needed.

## What it would and would not cover

Covers Prometheus, Alertmanager, ntfy, the lib-pi-06 host and the home internet connection, with
an alerting path that is entirely off-site. Does not cover ntfy-bridge or signal-bridge, which the
daily heartbeat in ticket 12 already exercises once a day.

## Open questions

- Is an outbound third-party dependency acceptable? It cuts against self-hosting ntfy, though
  `infra/roles/ntfy/tasks/main.yaml` already sets `upstream-base-url: https://ntfy.sh` for iOS
  push, so the push path depends on an outside service today. A ping service would see only that
  a ping arrived, with no alert content, so it exposes strictly less than the existing relay.
- Where does the ping URL live? It is a secret, so Ansible Vault, same as the ntfy token.
- Does this fold into the existing `dead_mans_switch` role and its timer, or get its own?
