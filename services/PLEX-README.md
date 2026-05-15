# Plex Helm Chart — Notes

Personal reference for the Plex deployment on the home lab k3s cluster.

## Networking

Plex networking is more complex than other *arr services because official
Plex clients (Apple TV, Samsung TV, iPad) don't just hit an HTTP endpoint.
They rely on a cloud-assisted discovery flow.

### How Plex Client Discovery Works

1. The client logs into your Plex account and asks plex.tv for a list of
   servers.
2. plex.tv returns all known connection URLs for your server — local IPs,
   `*.plex.direct` TLS endpoints, remote access, relay.
3. The client tries each URL in priority order until one connects.

Official apps strongly prefer `*.plex.direct` endpoints. These are hostnames
like `192-168-1-250.<cert-uuid>.plex.direct` that encode the server IP and
use a wildcard TLS cert that **Plex itself holds**. This means any reverse
proxy in the path must pass the TLS through untouched — it cannot terminate
it.

### Two Ingress Paths

This chart sets up two independent ingress paths:

- **Browser:** Standard `networking.k8s.io/v1` Ingress on Traefik's
  `websecure` entrypoint (port 443). Routes `plex.houli.eu` to the Plex
  service. Uses the cluster TLSStore default (`houli-eu-wildcard`). Works
  with any ingress controller.

- **Native apps:** Traefik-specific `IngressRouteTCP` on a dedicated
  `plex-tcp` entrypoint (port 32400) with `tls.passthrough: true`. Traefik
  forwards the raw TCP stream to Plex, which terminates TLS using its own
  `*.plex.direct` certificate. This is opt-in via
  `ingress.tcpPassthrough.enabled`.

### Traefik Configuration

The `plex-tcp` entrypoint must be added to the Traefik `HelmChartConfig` in
`kube-system`. This is an infrastructure-level change, not part of the Plex
chart:

```yaml
ports:
  plex-tcp:
    port: 32400
    expose:
      default: true
    exposedPort: 32400
    protocol: TCP
```

No separate MetalLB VIP is needed. Port 32400 is exposed on the existing
Traefik LoadBalancer IP (192.168.1.250). No conflict with port 443.

The old GDM/UDP discovery ports (32410, 32412, 32413, 32414) are not needed.
Clients discover via plex.tv cloud, not LAN multicast.

### ADVERTISE_IP

Plex auto-detects its own IP, which inside the cluster is the pod IP
(10.42.x.x) — useless to external clients. The `ADVERTISE_IP` env var tells
Plex to register reachable URLs with plex.tv instead:

```
http://plex.houli.eu:32400,http://192.168.1.250:32400
```

The `http://` prefix is intentional. Plex handles the TLS upgrade internally
for `*.plex.direct` connections. These URLs are starting points for the
client's connection negotiation.

**Important:** `ADVERTISE_IP` is only written to `customConnections` in
`Preferences.xml` on first run. If `Preferences.xml` already exists (e.g.
from a migration), the env var is ignored. You must either delete
`Preferences.xml` or manually inject `customConnections` via sed. See the
"Claim Token" section below.

## Claim Token

The Plex claim token links a server to your Plex account. It is a one-time
use token from [plex.tv/claim](https://plex.tv/claim) that expires after 4
minutes.

Once claimed, the association is stored in `Preferences.xml` on the config
volume. The token is never needed again unless you wipe the config or need to
re-claim.

### Ansible Workflow

The claim token is managed via the standard vault pattern:

- `vault_plex_claim_token` in `group_vars/all/vault.yaml`
- `plex_claim_enabled` in `roles/plex/defaults/main.yaml` (default: `false`)
- The Ansible role conditionally creates a Kubernetes secret and the Helm
  values enable `env.claimToken` — both gated on `plex_claim_enabled`

To re-claim:

1. Set `plex_claim_enabled: true` in defaults.
2. Get a fresh token from plex.tv/claim and update the vault.
3. If migrating or resetting, delete `Preferences.xml` from the config
   volume (see below).
4. Run the playbook. Move quickly — the token expires in 4 minutes.
5. Verify the server appears on your Plex account.
6. Set `plex_claim_enabled: false` and re-run the playbook.

### Deleting Preferences.xml

If `customConnections` is stale or the server identity needs resetting, you
don't need to wipe the whole config volume. Delete only `Preferences.xml` —
library metadata and watch history are preserved.

Scale down, run a maintenance pod, scale back up:

```bash
kubectl scale deploy/plex -n plex --replicas=0

kubectl run plex-maintenance -n plex --image=busybox --restart=Never --overrides='
{
  "spec": {
    "containers": [{
      "name": "plex-maintenance",
      "image": "busybox",
      "command": ["sh", "-c", "rm -f /config/Library/Application\\ Support/Plex\\ Media\\ Server/Preferences.xml && echo done"],
      "volumeMounts": [{"name": "config", "mountPath": "/config"}]
    }],
    "volumes": [{
      "name": "config",
      "persistentVolumeClaim": {"claimName": "pvc-plex"}
    }],
    "nodeSelector": {"node_type": "nuc"}
  }
}'

kubectl logs -n plex plex-maintenance
kubectl delete pod plex-maintenance -n plex
kubectl scale deploy/plex -n plex --replicas=1
```

### Verification

Check that `customConnections` is set correctly after startup:

```bash
kubectl exec -n plex deploy/plex -- \
  cat /config/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml \
  | tr ' ' '\n' | grep -i custom
```

Expected output:

```
customConnections="http://plex.houli.eu:32400,http://192.168.1.250:32400"/>
```

## Hardware Transcoding

The chart supports Intel Quick Sync hardware transcoding via `/dev/dri`
device mount, gated by `hardwareTranscoding.enabled` in values.

Requirements on the target node:

- `i915` kernel module loaded (`lsmod | grep i915`)
- `/dev/dri/renderD128` present
- The `render` group GID — check with `stat /dev/dri/renderD128`. On the NUC
  (Ubuntu 24.04) this is GID 993, not the typical 44. Set via
  `hardwareTranscoding.renderGroupId` in values.

The chart adds `supplementalGroups` with the render GID to the pod security
context, which is cleaner than running privileged.

## Debugging Checklist

If native apps can't connect:

1. Is the server reachable on plex.tv? Check Settings → Remote Access in the
   web UI.
2. Is port 32400 open on the Traefik LB?
   ```bash
   nc -zv 192.168.1.250 32400
   ```
3. Does the IngressRouteTCP exist?
   ```bash
   kubectl get ingressroutetcp -n plex
   ```
4. Is `ADVERTISE_IP` set in the pod env?
   ```bash
   kubectl exec -n plex deploy/plex -- env | grep -i advertise
   ```
5. Is `customConnections` correct in Preferences.xml?
   ```bash
   kubectl exec -n plex deploy/plex -- \
     cat /config/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml \
     | tr ' ' '\n' | grep -i custom
   ```
6. If `customConnections` is stale or missing, delete `Preferences.xml` and
   re-claim (see above).
