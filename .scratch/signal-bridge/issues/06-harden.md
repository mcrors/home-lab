Status: resolved

# M3: harden the bridge

## Context

The basic forward path works after ticket 05. This ticket adds retry logic to `forward.sh`, locks down secrets, and verifies the NetworkPolicy is active.

See `docs/alerting/signal-bridge-prd.md` section 5 (Features — From the forward script) and section 9 (Risks — risk 4).

## Scope

### `forward.sh` changes

Add a retry loop around the `curl` call:

- 3 attempts maximum.
- Delays: 2 seconds after the first failure, 4 seconds after the second.
- On success: write one log line and exit 0.
- After 3 failures: write a drop log line and exit 1.

Log line format on success:
```
topic=<NTFY_TOPIC> id=<NTFY_ID> result=ok
```

Log line format on drop:
```
topic=<NTFY_TOPIC> id=<NTFY_ID> result=dropped attempts=3
```

The script must still stay under 50 lines.

### Secrets audit

Confirm:
- `SIGNAL_ACCOUNT` and `GROUP_HOMELAB_ALERTS` come from the Secret, not from a ConfigMap or hardcoded value.
- The ntfy token comes from `client.yml` mounted from the Secret.
- No secret value appears in any log line.
- No secret value appears in a Deployment env block without a `secretKeyRef`.

### NetworkPolicy verification

Confirm the NetworkPolicy is blocking as intended:

1. Get a shell in a pod in a different namespace (e.g. the default namespace).
2. Attempt a curl to `signal-cli.ntfy.svc.cluster.local:3000`.
3. Confirm the connection times out or is refused.
4. Get a shell in the `signal-bridge` pod.
5. Confirm a curl to `http://signal-cli:3000/api/v1/rpc` succeeds (or reaches the daemon).

## Acceptance criteria

- Stop the `signal-cli` pod. Publish a message to `homelab-alerts`. Observe three retry attempts in the `signal-bridge` logs. Observe one drop log line. Confirm `signal-bridge` keeps running.
- A curl from outside the `ntfy` namespace to port 3000 on `signal-cli` times out.
- No log line contains the Signal account number, the ntfy token, or the message body of a filtered message.
