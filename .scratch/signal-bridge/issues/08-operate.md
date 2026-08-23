Status: ready-for-human
Blocked by: 07

# M5: operational hardening

## Context

The bridge is working end-to-end. This ticket covers the tasks needed to leave it in a maintainable state: backup protection for the account keys, and a README that covers the procedures someone would need to operate the bridge without reading the PRD.

See `docs/alerting/signal-bridge-prd.md` sections 6 (Non-functional requirements — Data) and 7 (Deployment — Upgrades).

## Scope

### Longhorn backup

1. Add the `signal-cli-data` PVC to the Longhorn NFS backup target.
2. Confirm the PVC appears in the Longhorn backup schedule.
3. Take a first manual PVC snapshot and confirm it completes.

### Monthly upgrade reminder

Set a recurring monthly calendar reminder: "Check for a new signal-cli release and upgrade if one is available." Upgrade procedure is in the README below.

### README for the signal-bridge repo

Write the full README for the `signal-bridge` GitHub repo. It should cover:

**Device link procedure** (condensed from PRD section 8):
- When to use it (first setup, or after a lost PVC).
- The exact commands, in order.
- How to delete the stale device on the iPhone before re-linking.

**Upgrade procedure**:
1. Snapshot the PVC.
2. Change the image tag in the Ansible role variable.
3. Run Ansible.
4. Send a test message.
5. Rollback: change the tag back and re-run Ansible. If the session is corrupted, restore the PVC snapshot.

**Adding a new topic**:
1. Create a Signal group on the phone.
2. List groups and get the group ID.
3. Add the group ID to Ansible Vault.
4. Add the topic to `client.yml.j2` in the Ansible role.
5. Run Ansible and restart the `signal-bridge` pod.

**Recovery — lost PVC**:
- Delete the stale linked device on the iPhone.
- Follow the device link procedure.
- Group IDs remain valid — no need to recreate groups.

## Acceptance criteria

- The `signal-cli-data` PVC appears in the Longhorn backup schedule with at least one completed snapshot.
- The monthly upgrade reminder is set.
- The README covers all four procedures above.
- A person following the README can link a new device or add a topic without reading the PRD.
