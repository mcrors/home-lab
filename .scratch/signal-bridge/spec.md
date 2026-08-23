Status: ready-for-agent

# Signal bridge

See `docs/alerting/signal-bridge-prd.md` for the full specification.

## Decisions recorded outside the PRD

- Forward `homelab-alerts` topic only. No other topics in scope for v1.
- No priority filter. Forward all priorities. Tighten later when noise becomes a problem.
- No heartbeat. Out-of-band ntfy morning message acts as the canary instead.
- No message replay on subscriber restart. Accept the gap for v1.
- `forward.sh` stays a shell script. Alpine + jq + curl. Under 50 lines.
- signal-cli upgrade cadence: monthly manual check. Version notification automation is a future ticket.
