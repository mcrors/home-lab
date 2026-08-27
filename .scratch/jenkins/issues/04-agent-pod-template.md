Status: ready-for-agent
Blocked by: 03

# M2: add the Kubernetes cloud and the DinD pod template

## Context

The controller runs no builds. This ticket gives it an agent: an ephemeral pod with a privileged `docker:dind` sidecar, one at a time, never on the controller's node.

See `docs/jenkins/jenkins-prd.md` section 4 (The agent, Concurrency, Placement).

## Scope

Extend `infra/roles/jenkins/files/values.yaml`.

### Kubernetes cloud

- `agent.enabled: true`
- `agent.containerCap: 1`
- `agent.podRetention: "Never"`
- `agent.idleMinutes: 0`
- `agent.websocket: false` — the `jenkins-agent` Service on port 50000 is in-cluster, so direct JNLP works

### The pod template

Define one template named `docker-arm64` with the label `docker`. Two containers:

**`jnlp`**
- image `jenkins/inbound-agent` at the digest recorded in ticket 01
- request `100m` CPU and `256Mi` memory, limit `512Mi` memory, no CPU limit
- env `DOCKER_HOST=tcp://127.0.0.1:2375`

**`dind`** (sidecar)
- image `docker:28-dind` at the digest recorded in ticket 01
- `privileged: true`
- env `DOCKER_TLS_CERTDIR=""` so the daemon listens on plain TCP
- args `--host=tcp://127.0.0.1:2375` — see the bind address note below
- request `250m` CPU and `512Mi` memory, limit `1Gi` memory, no CPU limit
- `emptyDir` at `/var/lib/docker` for the layer store

### Bind the daemon to loopback

Ticket 01 found the image default binds **every** interface in the pod, not loopback. The probe logged `API listen on [::]:2375`. That address includes the pod IP, so any pod in the cluster could reach port 2375, and access to that port is equal to root on the agent's node.

Pass `--host=tcp://127.0.0.1:2375` to the `dind` container so the daemon binds loopback only. Set the matching `DOCKER_HOST` on `jnlp`. Do not rely on `DOCKER_TLS_CERTDIR=""` alone — it removes TLS, it does not narrow the bind address.

### Placement

- required node affinity `node_type=pi`
- preferred node affinity `node_size=large`
- required `podAntiAffinity` against the controller pod's labels, `topologyKey: kubernetes.io/hostname`

Use the controller's real label selector, not a guess. Read it from the running StatefulSet — the chart renders a StatefulSet, not a Deployment.

### Verify with a smoke-test pipeline

Create a throwaway pipeline job that runs on the `docker` label and executes:

1. the daemon wait below — the daemon is not ready when the container starts
2. `docker version` — proves the daemon is reachable from `jnlp`
3. a build of a two-line `Dockerfile` based on `alpine:3.20`
4. `docker image ls` to confirm the image exists

### Wait for the daemon

Ticket 01 measured 17 seconds from container start to `Daemon has completed initialization`. An exec at 13 seconds failed with `Cannot connect to the Docker daemon`. The Kubernetes plugin waits for the container to start, not for the daemon to accept connections, so a build that calls `docker` in its first step fails intermittently.

Every pipeline starts with this wait:

```sh
timeout 120 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done'
```

Put it in the smoke-test job here. Ticket 06 puts it in each application `Jenkinsfile`.

Delete the job when the ticket closes. Real jobs arrive in ticket 06.

## Notes

- Do not add a readiness probe to the sidecar. The Kubernetes plugin does not wait for sidecars. The wait belongs in the pipeline.
- Do not mount the host Docker socket. The nodes run containerd, not Docker. There is no socket to mount.
- Ticket 01 already proved the mechanism on `lib-pi-05`: a privileged `docker:28-dind` container built and ran a native `arm64` image for a sidecar client. This ticket wires it into Jenkins, it does not re-prove it.

## Acceptance criteria

- A build on the `docker` label creates an agent pod, runs, and the pod is deleted afterwards.
- `docker version` reports both client and server from inside the `jnlp` container.
- The test image builds and appears in `docker image ls`.
- The agent pod scheduled onto a pi that is not the controller's node.
- The daemon is not reachable from outside the agent pod. From another pod, `wget -T3 -O- http://<agent-pod-ip>:2375/_ping` fails to connect.
- Starting a second build while one runs leaves it queued — no second agent pod appears.
- Running the role again is idempotent.
