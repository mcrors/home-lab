Status: resolved
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

## Answer

Deployed 2026-09-15. Helm release `jenkins` at revision 4, chart `jenkins-5.9.54`. The cloud and the
`docker-arm64` template reached Jenkins through the JCasC sidecar with no controller restart. The
`checksum/config` annotation on the StatefulSet covers `config.yaml` only, so a JCasC change reloads
in place:

```
Writing /var/jenkins_home/casc_configs/jcasc-default-config.yaml
None sent to http://localhost:8080/reload-configuration-as-code/ ... Response: 200 OK
```

### Acceptance criteria

| Criterion | Result |
|---|---|
| A build creates an agent pod, runs, and the pod is deleted afterwards | pass, builds 5 and 6 each got their own pod, both deleted |
| `docker version` reports client and server | pass, client 28.5.2 `linux/arm64`, server 28.5.2 `linux/arm64` |
| The test image builds and appears in `docker image ls` | pass, `ticket04-smoke:1` at 8.82MB, and `docker run` printed `aarch64` |
| The agent scheduled onto a pi that is not the controller's node | pass, `lib-pi-05`, controller on `lib-pi-01` |
| The daemon is not reachable from outside the agent pod | pass, `wget -T3` from a pod on `lib-nuc-01` got connection refused |
| A second build queues with no second agent pod | pass, build 6 waited while build 5 held the only pod |
| Running the role again is idempotent | pass, `changed=0`, release still at revision 4 |

The criterion about `docker version` was written as "from inside the `jnlp` container". That is not
where it ran. See Finding H.

### Finding G - the dind args need `dockerd` as the first token

The first two builds died before their first step. The `dind` container exited 1 about ten seconds
after start, and `podRetention: Never` took the log with the pod. Reproduced standalone on
`lib-pi-05`:

```
failed to load listeners: failed to allocate daemon listening port 2375
(err: Bind for 0.0.0.0:2375 failed: port is already allocated)
```

The cause is in `dockerd-entrypoint.sh` in the image:

```sh
# no arguments passed
# or first arg is `-f` or `--some-option`
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	...
	set -- dockerd --host="$dockerSocket" --host=tcp://0.0.0.0:2375 "$@"
```

The ticket specified `args: "--host=tcp://127.0.0.1:2375"`. That starts with a dash, so the
entrypoint took this branch, prepended its own `--host=tcp://0.0.0.0:2375`, and the two listeners
collided on one port. The daemon refused to start at all.

Naming `dockerd` explicitly skips the branch and keeps the rest of the entrypoint, which still does
the PID file cleanup, the iptables checks, and the cgroup setup. The values now read:

```yaml
args: "dockerd --host=tcp://127.0.0.1:2375"
```

Ticket 01 Finding B is now proven rather than inferred:

```
API listen on 127.0.0.1:2375
tcp  0  0  127.0.0.1:2375  0.0.0.0:*  LISTEN
```

### Finding H - `jnlp` has no Docker client, so a third container runs the steps

`jenkins/inbound-agent` carries no container tooling. Every one of `docker`, `podman`, `buildah`,
`nerdctl`, `ctr`, `crictl`, `img` and `skopeo` is absent. It is a Debian base with a JRE, the agent
jar, and ordinary tools such as `git`.

The PRD had build steps running in `jnlp` and reaching the daemon through `DOCKER_HOST`. The network
half of that is correct, because containers in a pod share a network namespace and loopback crosses
between them. The tooling half is wrong, because `docker build` is a client that has to exist in the
container where the step runs. Filesystems are not shared between containers in a pod.

The template now holds a third container, `docker:28-cli`, held open with `command: cat` and a TTY.
A pipeline selects it with `container('docker')`. This is the ordinary multi-container idiom for the
Kubernetes plugin.

Two alternatives were considered and rejected. A custom agent image holding the agent and the tools
would keep Jenkinsfiles unwrapped, and it puts a bootstrap image on the maintenance list that has to
be built before Jenkins can build anything. Running the steps inside `dind` itself would work,
because `docker:28-dind` does ship the client at `/usr/local/bin/docker`, and it runs every build
step as root inside the privileged container.

**This changes ticket 06.** Each `Jenkinsfile` wraps its Docker steps in `container('docker')`, or
sets `defaultContainer 'docker'` once for the pipeline. The daemon wait goes inside that same
container.

### Finding I - additionalContainers entries need an `args` key

Adding the `docker` container without `args` failed the Helm render:

```
_helpers.tpl:462:55 executing "jenkins.casc.podTemplate" at <"^$">: invalid value; expected string
```

The chart pipes `args` through `replace "$" "^$"` for every additional container and a missing key
arrives as nil. `args: ""` is required even when the container takes no arguments. The failure
happened at render time, so the release was never touched.

### Recorded digest

Ticket 01 did not record a client image. Resolved 2026-09-15 from the registry API:

| Image | Index (tag) digest | arm64 child digest |
|---|---|---|
| `docker:28-cli` | `sha256:625d9431a9f54c5a2bc90f24f0e1c3d55b1349fd857dd85035f98c2c9acbdd4d` | `sha256:3f531683b548300f6d21ac352553215c67713f31105cd23e09cd2a4aa25428a8` |

All three images are pinned by index digest, carried on the tag as `tag@sha256:...`, because the
chart renders the image reference as `repository:tag`.

### How the values are structured

The chart's `agent` keys have three gaps. They cannot express pod affinity. They cannot set
environment variables on a container declared under `additionalContainers`. A volume declared under
`agent.volumes` mounts into every container of the pod. `agent.yamlTemplate` carries exactly those
three things: the node affinity and the anti-affinity against the controller, `DOCKER_TLS_CERTDIR=""`
on `dind`, and the `emptyDir` mounted into `dind` alone. The Kubernetes plugin merges that fragment
onto the generated pod, matching containers by name.

The alternative was `disableDefaultAgent: true` with the whole template hand written as raw JCasC
under `agent.podTemplates`. That nests YAML inside YAML twice and gives up the chart's own wiring of
the service account, the label string, and the template id.

`resourceLimitCpu` renders as null for all three containers, and the live pod spec confirms no CPU
limit is set on any of them.

### Cluster state

The throwaway pipeline `ticket04-smoke` is deleted and returns 404. The three debug pods used to
isolate Finding G and Finding H are deleted. No agent pod remains. The controller is untouched at
`jenkins-0`, 2/2, 0 restarts, still on `lib-pi-01`.
