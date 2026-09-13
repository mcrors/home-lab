Status: needs-triage

# Cluster access control

Services in this cluster are reachable from any pod, because almost nothing carries a
NetworkPolicy. Opened 2026-09-13 after the Transmission RPC finding below; not yet triaged
or scoped beyond that one ticket.

One NetworkPolicy exists as precedent: `signal-cli-ingress` in the `ntfy` namespace, from
`infra/roles/signal_bridge`. k3s is not started with `--disable-network-policy`, so its
built-in controller should enforce policies, but that was **not** verified empirically.
Verify before relying on a policy as a fix.

## Tickets

| # | Title | Status |
| --- | --- | --- |
| 01 | Transmission RPC accepts unauthenticated calls from any pod | needs-triage |
