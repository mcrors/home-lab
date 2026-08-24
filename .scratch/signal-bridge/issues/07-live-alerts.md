Status: resolved

# M4: connect Alertmanager and confirm live alerts reach Signal

## Context

With the bridge hardened, connect the real Alertmanager alert pipeline. Confirm that a genuine alert travels the full path from Alertmanager to the homelab-alerts Signal group.

See `docs/alerting/signal-bridge-prd.md` section 10 (Milestones — M4).

## Scope

1. Check which ntfy topic the existing Alertmanager bridge is publishing to. If it is not `homelab-alerts`, update its configuration to send to `homelab-alerts`.

2. Fire a test alert. The simplest method is to temporarily silence an existing alert receiver so Alertmanager fires a firing alert, or to use `amtool alert add` to inject a synthetic alert.

3. Watch the `signal-bridge` logs to confirm it receives and forwards the message.

4. Confirm the message appears in the homelab-alerts Signal group.

5. Confirm the phone shows a notification.

## Notes

- Do not change the Alertmanager bridge in a way that drops existing ntfy delivery. The PRD non-goal 4 states that the Alertmanager bridge stays as it is. Only change the topic it publishes to if the topic name does not already match.
- If the Alertmanager bridge already publishes to `homelab-alerts`, step 1 is a no-op.

## Acceptance criteria

- A real Alertmanager alert reaches the homelab-alerts Signal group.
- The phone shows a notification for that alert.
- The ntfy delivery path (Alertmanager → ntfy server → ntfy app) is unaffected.
