Status: resolved

# M2: deploy to cluster and link device

## Context

With the image on Docker Hub and the Ansible role written, deploy the signal-bridge to the cluster. Then link the signal-cli daemon as a secondary device on the iPhone. This is the first end-to-end test on the cluster.

See `docs/alerting/signal-bridge-prd.md` section 8 (Registration procedure) for the full link procedure.

## Scope

### Deploy

1. Add the group ID vault variable as a placeholder (empty string) so the role can render the Secret.
2. Run the Ansible role to apply all objects.
3. Confirm the `signal-cli` pod reaches Running state on an x-large node.
4. Confirm the `signal-bridge` pod reaches Running state (it will retry sends until the link is complete — that is expected).

### Link

Follow section 8 of the PRD. Use these steps from the laptop:

1. Open a port-forward to the daemon:
   ```
   kubectl -n ntfy port-forward deploy/signal-cli 8080:8080
   ```

2. Open a browser and navigate to:
   ```
   http://localhost:8080/v1/qrcodelink?device_name=signal-bridge
   ```

3. Open Signal on the iPhone. Go to Settings → Linked Devices → Link New Device. Scan the QR code on the laptop screen.

4. Confirm the iPhone lists a device named `signal-bridge`.

### Collect group IDs

1. Create a Signal group named `homelab-alerts` on the phone. Add the linked account. (A single-member group is confirmed working from ticket 01.)

2. List groups to get the group ID (exact endpoint confirmed during M0 — see ticket 01 findings).

3. Store the group ID for `homelab-alerts` in Ansible Vault under `signal_group_homelab_alerts`.

4. Re-run the Ansible role to update the Secret with the real group ID.

5. Restart the `signal-bridge` pod so it picks up the updated Secret.

### Verify

1. Publish a test message to the `homelab-alerts` ntfy topic.
2. Confirm the message appears in the homelab-alerts Signal group within 5 seconds.
3. Confirm the message appears as a notification on the iPhone.
4. Close the port-forward.

## Acceptance criteria

- Both pods are Running on the cluster.
- The iPhone lists `signal-bridge` under linked devices.
- A test ntfy message appears in the homelab-alerts Signal group within 5 seconds.
- The phone shows a notification for that message.
