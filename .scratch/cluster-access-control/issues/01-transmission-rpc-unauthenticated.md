Status: needs-triage

# Transmission RPC accepts unauthenticated calls from any pod

Transmission has `rpc-authentication-required: false`, an empty `rpc-username`, and both
`rpc-whitelist-enabled` and `rpc-host-whitelist-enabled` false, bound to `0.0.0.0:9091`
(`/config/transmission-home/settings.json`). No NetworkPolicy limits who can reach it, so any
pod in the cluster can drive the RPC: add a torrent, or set `download-dir` to any path the
container can write, which includes the NFS media and downloads mounts.

Found on 2026-09-13 while adding the homepage Transmission widget, which needed no credentials.
The widget did not cause this and does not worsen it; see
`.scratch/homepage/issues/05-service-widgets.md`.

Two fix directions, not yet chosen: turn RPC auth on and give the widget credentials from the
vault, or leave auth off and add a NetworkPolicy admitting only the homepage pod. The second
depends on k3s actually enforcing policies here, which is unverified.
