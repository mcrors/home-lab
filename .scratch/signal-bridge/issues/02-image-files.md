Status: ready-for-agent

# M1: write signal-bridge image files

## Context

The subscriber pod runs a custom image. The image holds three binaries: ntfy, jq, and curl. A separate GitHub repo holds the image source. This ticket writes the four files that repo needs.

See `docs/alerting/signal-bridge-prd.md` sections 7.1 (Image build) and 5 (Features — From the forward script).

## Scope

Write the following four files to a local staging directory (e.g. `scratch/signal-bridge-image/`). Ticket 03 creates the GitHub repo and pushes them.

### `Dockerfile`

```dockerfile
FROM alpine:3.20
COPY --from=binwiederhier/ntfy:v2.11.0 /usr/bin/ntfy /usr/bin/ntfy
RUN apk add --no-cache jq curl bash
COPY forward.sh /opt/forward.sh
RUN chmod +x /opt/forward.sh
ENTRYPOINT ["ntfy", "subscribe", "--from-config"]
```

### `forward.sh`

The script forwards one ntfy message to a Signal group via the signal-cli JSON-RPC endpoint.

Requirements:
- Takes the Signal group ID as `$1`.
- Reads `SIGNAL_ACCOUNT` from the environment (the Signal account phone number).
- Reads `NTFY_MESSAGE`, `NTFY_TITLE`, `NTFY_TOPIC`, and `NTFY_ID` from the environment (set by the ntfy CLI).
- Formats the message as: `[<topic>] <title>: <message>` (omit the title prefix if `NTFY_TITLE` is empty).
- Builds the REST request body using `jq`. jq handles escaping. Exact body confirmed during M0 — see ticket 01 findings.
- POSTs to `http://signal-cli:8080/v2/send` using `curl -sf`.
- Writes one log line to stdout: `topic=<topic> id=<NTFY_ID> result=ok` on success, `result=error` on failure.
- Never writes `SIGNAL_ACCOUNT` or `NTFY_MESSAGE` to the log.
- Stays under 50 lines. No retry in this ticket — retry is added in ticket 06.

### `Jenkinsfile`

Follow the `arr-exporter` Jenkins pipeline pattern in this repo:
- Use the DinD sidecar for the Docker build.
- Tag the image with the short git SHA: `ghcr.io/<user>/signal-bridge:<sha>`.
- Never push a `latest` tag.
- Push to GHCR.

### `README.md`

Minimal placeholder. Full operating procedures come in ticket 08.

Content: one-line description of what the image does, and a note that the README is a work in progress.

## Acceptance criteria

- `docker build -t signal-bridge .` succeeds from the staging directory.
- `forward.sh` is under 50 lines.
- The Jenkinsfile matches the arr-exporter build pattern.
- No secret value appears in any of the four files.
