Status: resolved

# M0: verify signal-cli linked-device flow locally

## Context

Before any cluster work, confirm that the bbernhard/signal-cli-rest-api image can link as a secondary device and deliver a group message as a phone notification. A negative result changes the design. This ticket must complete before tickets 05, 06, 07, 08.

See `docs/alerting/signal-bridge-prd.md` section 3 (Feasibility — Unverified) and section 8 (Registration procedure).

## Scope

Run bbernhard/signal-cli-rest-api locally using Docker. Do not touch the cluster.

```bash
docker run -it \
  -p 8080:8080 \
  -e MODE=normal \
  -v $(pwd)/signal-cli-data:/home/.local/share/signal-cli \
  bbernhard/signal-cli-rest-api
```

Steps:

1. Open `http://localhost:8080/v1/qrcodelink?device_name=signal-bridge` in a browser.
2. Scan the QR code with the iPhone Signal app (Settings → Linked Devices → Link New Device).
3. Confirm the iPhone lists a device named `signal-bridge`.
4. Create a test Signal group on the phone.
5. Send a test message to that group via the bbernhard REST API.
6. Confirm the message arrives as a notification on the iPhone.
7. List groups via the REST API and record the group ID format.

## What to verify

- Does a single-member Signal group receive notifications on the phone?
- Does a group message from a linked device raise a notification (not just appear silently)?
- What is the exact request body for `/v2/send`?
- What is the endpoint for listing groups?
- Does `MODE=json-rpc` work for sending after linking in `MODE=normal`? (Important for daemon operation on the cluster.)

## Findings so far

- The bbernhard image exposes its own REST API. Native signal-cli JSON-RPC endpoints (`/api/v1/rpc`) are not exposed.
- The API base path is `/v1/` and `/v2/`, not `/api/v1/`.
- Device linking uses `GET /v1/qrcodelink?device_name=<name>` in a browser.
- `MODE=normal` confirmed working for the QR code linking step.
- Port is 8080, not 3000.
- PRD section 8 and architecture updated to reflect these findings.

## Confirmed findings

**Linking:** `GET /v1/qrcodelink?device_name=<name>` in a browser. Scan with iPhone Signal app (Settings → Linked Devices → Link New Device).

**Account listing:** `GET /v1/accounts` — returns the linked account number.

**Group listing:** `GET /v1/groups/<number>` — returns all groups. If a newly created group is missing, trigger `GET /v1/receive/<number>` first.

**Group ID format:** `group.<base64string>=`

**Send:** `POST /v2/send` with body:
```json
{
  "message": "<text>",
  "number": "<account>",
  "recipients": ["<group-id>"]
}
```

**Notifications:** Group messages from a linked device raise notifications on the iPhone. Single-member group confirmed working.

**Sender display:** Messages appear as "From me" in Signal. No per-device alias is possible — this is a protocol constraint. Use message text formatting (`[topic] title: message`) to add context instead.

**MODE:** `MODE=normal` confirmed for linking and sending. `MODE=json-rpc` to be used for cluster deployment (daemon receives continuously). Linking in normal mode, then switching to json-rpc mode for operation is the expected pattern.

## Acceptance criteria

- A message sent from the laptop via local Docker appears as a notification on the iPhone.
- Section 8 of the PRD is complete with verified send and list-groups endpoints.

## Out of scope

- Anything on the cluster.
- Setting up the permanent group. Use a throwaway group for this test.
