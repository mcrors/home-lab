# PRD — Jenkins on k3s

**Working name:** `jenkins`
**Status:** Draft
**Date:** 2026-08-27
**Writing style:** ASD-STE100

---

## Names used in this document

| Name | Meaning |
|---|---|
| the controller | The Jenkins server pod. Runs the web UI. Runs no builds. |
| the agent | A build pod. The Kubernetes plugin creates it for one build, then deletes it. |
| the DinD sidecar | The `docker:dind` container inside the agent pod. Provides the Docker daemon. |
| the chart | The upstream `jenkinsci/jenkins` Helm chart. |
| the local chart | The hand-written chart at `jenkins/` in this repository. This project deletes it. |
| JCasC | Jenkins Configuration as Code. A plugin that applies a YAML file to Jenkins at startup. |
| the org folder | A GitHub Organization Folder. One Jenkins object that scans a GitHub account and creates one job for each repository that holds a `Jenkinsfile`. |
| the old home | The abandoned `JENKINS_HOME` at `192.168.1.96:/export/jenkins`. |

---

## 1. Problem

The homelab has no working CI. Three facts describe the current state:

1. The local chart at `jenkins/` is not deployed. The cluster holds no `jenkins` namespace.
2. `https://jenkins.houli.eu` answers `404` from Traefik. Pi-hole resolves the name to `192.168.1.250`. No Ingress claims it.
3. The old home holds 259 plugins and Jenkins 2.535. The `jobs/` directory is empty. No job definition survives.

The homelab already depends on Jenkins. Two images need a build pipeline: `arr-exporter` and `nfty-signal-bridge`. The signal-bridge Deployment runs the tag `cad878b` today. No pipeline can produce the next tag.

The local chart cannot close this gap. It has these defects:

1. The image tag is hard-coded in the Deployment template.
2. The storage is an NFS PersistentVolume. Jenkins does not support NFS for `JENKINS_HOME`. File locking and rename semantics cause corruption.
3. The chart defines no agent. It builds nothing.
4. The chart holds no configuration. Every setting needs a human in the UI.

**Volume.** The homelab holds a small number of repositories. Builds are rare — a few each week. Build concurrency of one is enough. The design must stay simple, not scale.

---

## 2. Goal and non-goals

### Goal

Jenkins runs on the k3s cluster and builds container images. Ansible deploys it. The configuration lives in this repository.

One controller runs the UI. One agent pod at a time runs a build. The agent builds images with Docker.

### In scope

1. Deploy the upstream chart with an Ansible role.
2. Run the controller with zero executors.
3. Create agent pods on demand, each with a DinD sidecar.
4. Hold the Jenkins system configuration in JCasC.
5. Discover jobs from GitHub with an org folder.
6. Take credentials from Ansible Vault.
7. Delete the local chart.

### Non-goals

This project does not do these things:

1. Build multi-architecture images. Section 4 records the constraint.
2. Expose Jenkins to the internet. No public endpoint. No Cloudflare tunnel.
3. Accept GitHub webhooks. Section 4 records the consequence.
4. Migrate the old home. Nothing in it is needed.
5. Cache Docker layers between builds. Section 9 records the cost.
6. Run more than one build at a time.
7. Replace the media-stack Helm charts under `services/helm/`.

---

## 3. Feasibility

### Confirmed

1. The chart `jenkinsci/jenkins` version `5.9.54` exists and carries appVersion `2.568.2`.
2. The chart defaults to `controller.numExecutors: 0`. This matches the intent in `TODO.md`.
3. The chart supports `controller.JCasC.configScripts`, `agent`, and `agent.podTemplates`.
4. No `jenkins` namespace exists. The deploy starts clean.
5. The old home holds no jobs. No migration is needed.
6. Pi-hole already maps `jenkins.houli.eu` to `192.168.1.250`, the Traefik LoadBalancer address.
7. Prometheus already probes `https://jenkins.houli.eu/login` through the blackbox exporter. The probe fails today. It passes when the Ingress exists.
8. Traefik holds the wildcard certificate `houli-eu-wildcard` as its default. The Ingress needs no per-host certificate.
9. `jenkins.houli.eu` does not resolve on public DNS. Only Pi-hole answers for it.

### Constraints

1. **Architecture.** Every pi and potato is `arm64`. Only `lib-nuc-01` is `amd64`. An agent on a pi produces `arm64` images only.
2. **Memory.** A medium pi holds 4 GB. Measured use is 1449–1895 MiB. Free memory is near 2.3 GiB. The controller and an agent do not both fit on one medium pi.
3. **No webhooks.** GitHub cannot reach `jenkins.houli.eu`. Trigger comes from periodic scanning.
4. **Privilege.** The DinD sidecar needs `privileged: true`. The same nodes run Longhorn.

### Verified

Ticket 01 answered these on 2026-08-27. The full evidence is in `.scratch/jenkins/issues/01-verify-assumptions.md`.

1. **arm64 images.** `jenkins/jenkins:2.568.2-jdk21`, `jenkins/inbound-agent:3385.vf1123fb_515da_-1`, and `docker:28-dind` all publish a `linux/arm64` manifest. The digests are recorded in the ticket. The chart composes the controller tag from its own appVersion, so the role sets no controller tag and no agent tag.
2. **Privileged admission.** k3s admits a privileged pod with no policy change. No namespace carries a PodSecurity label, the PodSecurityPolicy API is absent, and no admission policy or webhook filters pods. A live probe on `lib-pi-05` built an `arm64` image through the DinD sidecar.
3. **Secrets mount.** The chart mounts `controller.additionalExistingSecrets` at `/run/secrets/additional` and sets `SECRETS` to the same path. Each key becomes a file named `<secret name>-<keyName>`. JCasC reads it as `${jenkins-credentials-github-pat}`. The admin password takes a separate path — see section 7.
4. **GitHub token scopes.** A classic PAT with `public_repo` is enough. Every repository in the account is public. Section 7 records the detail.

Ticket 01 also corrected three points in this document: the chart renders a StatefulSet and not a Deployment, the Docker daemon does not bind loopback by default, and the daemon is not ready when its container starts. Sections 4, 6, and 7 carry the corrected text.

---

## 4. Architecture

### Overview

```
                     Pi-hole: jenkins.houli.eu -> 192.168.1.250
                                     |
                              Traefik (websecure)
                                     |
                            Ingress: jenkins.houli.eu
                                     |
   namespace: jenkins
   +---------------------------------------------------------------+
   |                                                                |
   |   StatefulSet: jenkins (controller)        [medium pi, arm64]  |
   |     - 0 executors                                              |
   |     - JCasC from the chart values                              |
   |     - PVC jenkins (Longhorn, 8Gi)                              |
   |                          |                                     |
   |                          | Kubernetes plugin creates a pod     |
   |                          v                                     |
   |   Pod: jenkins-agent-xxxxx                 [any pi, not the    |
   |     +-----------------+  +------------------+  controller's]   |
   |     | jnlp            |  | dind (privileged)|                  |
   |     | build steps     |->| Docker daemon    |                  |
   |     +-----------------+  +------------------+                  |
   |            DOCKER_HOST=tcp://127.0.0.1:2375                     |
   |                                                                |
   +---------------------------------------------------------------+
                                     |
                            push arm64 image
                                     v
                              Docker Hub (rhoulihan/*)
```

### The controller

The controller runs the UI and the scheduler. It runs no build. `numExecutors` is `0`. A build with no agent stays in the queue.

The controller reads its whole system configuration from JCasC at startup. The PVC holds job history, build logs, and plugin binaries.

### The agent

The Kubernetes plugin creates one pod for each build. The pod holds two containers:

1. `jnlp` — the `jenkins/inbound-agent` image. Runs the pipeline steps.
2. `dind` — the `docker:dind` image. Runs `dockerd`. Runs privileged.

The two containers share the pod network. The `jnlp` container reaches the daemon at `tcp://127.0.0.1:2375`. The pipeline needs no socket mount and no permission fix.

`DOCKER_TLS_CERTDIR` is empty. The daemon then listens on plain TCP.

**Bind address.** The image default binds every interface in the pod, which includes the pod IP. Any pod in the cluster could then reach port 2375, and that access is equal to root on the agent's node. The `dind` container therefore overrides the bind address with `--host=tcp://127.0.0.1:2375`. The `jnlp` container uses the matching `DOCKER_HOST`. Only the containers in the agent pod reach the daemon.

**Startup delay.** The daemon needs approximately 17 seconds to accept connections. The Kubernetes plugin waits for the container to start, not for the daemon to be ready. A pipeline that calls `docker` immediately fails. Each pipeline waits for the daemon before its first `docker` command.

The pod is deleted when the build ends. `podRetention` is `Never`.

### Concurrency

`containerCap` is `1`. `instanceCap` on the template is `1`. One agent pod exists at a time. A second build waits.

This is deliberate. Two DinD pods on one pi exhaust memory.

### Placement

| Pod | Required | Preferred | Reason |
|---|---|---|---|
| controller | `node_type=pi` | `node_size=medium` | Keeps the 8 GB pi free for builds. |
| agent | `node_type=pi` | `node_size=large` | pi-05 holds the most free memory. |

The agent pod also carries a required `podAntiAffinity` against the controller pod, with `topologyKey: kubernetes.io/hostname`. The controller and an agent never share a node.

pi-05 has an unresolved crash history. The preference is soft. A build lands on another pi when pi-05 is unavailable. The design degrades, it does not stop.

### Architecture of the built images

Builds run on `arm64`. The images are `arm64` only.

This matches where the images run today. `signal-bridge` runs on the potatoes. All potatoes are `arm64`.

An `arm64` image does not run on `lib-nuc-01`. Section 9 records this risk and the escape hatch.

### Job discovery

One org folder scans the GitHub account. It creates one multibranch pipeline for each repository that holds a `Jenkinsfile`. A new repository with a `Jenkinsfile` becomes a job with no further action.

The `Jenkinsfile` in each application repository holds the build steps. The org folder holds only the discovery rules. Neither lives in this repository.

The org folder rescans every 15 minutes. This replaces webhooks. Trigger latency is up to 15 minutes.

---

## 5. Features

### From the chart

1. Controller StatefulSet, Service, ServiceAccount, and RBAC for pod creation.
2. Ingress with the Traefik class.
3. Plugin installation from a pinned list.
4. JCasC delivered as a ConfigMap and mounted into the controller.
5. Agent pod templates rendered into the Kubernetes cloud configuration.

### From JCasC

1. `jenkinsUrl` set to `https://jenkins.houli.eu`. This clears the reverse proxy warning recorded in `TODO.md`.
2. Security realm: local user database. Signup disabled. Anonymous read denied.
3. The Kubernetes cloud and the DinD pod template.
4. Credentials read from a mounted Secret.
5. The org folder and its scan trigger.

### From Ansible

1. Helm repository, namespace, and release management. The pattern follows `infra/roles/alertmanager`.
2. A Secret rendered from Ansible Vault values.

### Known gaps

1. No Docker layer cache between builds. Each build pulls base images again.
2. No build trigger from GitHub. Scanning only.
3. No `amd64` build path.
4. Plugin versions float unless `initializeOnce` is set.

---

## 6. Non-functional requirements

### Resources

| Container | CPU request | CPU limit | Memory request | Memory limit |
|---|---|---|---|---|
| controller | 500m | none | 1Gi | 1536Mi |
| jnlp | 100m | none | 256Mi | 512Mi |
| dind | 250m | none | 512Mi | 1Gi |

No CPU limit applies to the controller. A CPU limit throttles the JVM and makes the UI slow.

`javaOpts` sets `-XX:MaxRAMPercentage=70.0`. The heap then tracks the memory limit.

### Availability

One replica. The chart renders a StatefulSet, so an update stops the old pod before it starts the new one. No `strategy` value applies — that field belongs to a Deployment. The PVC is `ReadWriteOnce`, so two controllers cannot run together.

Jenkins is offline during an upgrade or a node drain. This is acceptable. No service depends on Jenkins being up.

### Startup

The controller installs plugins at each start until `initializeOnce` is set to `true`. First start takes several minutes on a pi.

### Security

1. Anonymous read is denied.
2. The admin password comes from Ansible Vault, never from the chart default.
3. The DinD sidecar is privileged and is root-capable. It runs only in the `jenkins` namespace.
4. No Secret value appears in this repository. Templates only.
5. The Docker daemon binds `127.0.0.1` only. This needs the explicit `--host` flag in section 4. The image default binds every interface in the pod.

### Data

The PVC uses the Longhorn storage class. The size is 8 GiB. Access mode is `ReadWriteOnce`.

Add the PVC to the Longhorn backup target after the first successful build.

A lost PVC costs the build history. It does not cost the configuration. JCasC and the org folder rebuild the rest.

### Maintainability

The chart version is pinned in `defaults/main.yaml`. The plugin list is pinned in `files/values.yaml`. An upgrade is a version change and a role run.

---

## 7. Deployment

### Method

Ansible installs the upstream chart. This project writes no chart.

The role follows `infra/roles/alertmanager`: add the Helm repository, refresh the cache, create the namespace, then run `kubernetes.core.helm` with `files/values.yaml`.

### Location

The role is `infra/roles/jenkins`. A new playbook `infra/playbooks/ci.yaml` runs it. `infra/playbook.yaml` imports the playbook under the `ci` tag.

Jenkins is platform tooling, not a user application. It belongs beside Alertmanager and ntfy, not beside the media stack.

### Namespace

`jenkins`. Nothing else runs in it.

### Objects

| Object | Name | Source | Purpose |
|---|---|---|---|
| Namespace | `jenkins` | Ansible | Holds the release |
| Secret | `jenkins-credentials` | Ansible, from Vault | Admin password, GitHub PAT, Docker Hub token |
| StatefulSet | `jenkins` | chart | The controller |
| Service | `jenkins` | chart | ClusterIP on port 8080 |
| Service | `jenkins-agent` | chart | ClusterIP on port 50000 for inbound agents |
| PersistentVolumeClaim | `jenkins` | chart | `JENKINS_HOME`, Longhorn, 8Gi |
| Ingress | `jenkins` | chart | `jenkins.houli.eu`, Traefik |
| ConfigMap | `jenkins` | chart | The controller init scripts |
| ConfigMap | `jenkins-jenkins-jcasc-config` | chart | The JCasC YAML |
| ConfigMap | `jenkins-tests` | chart | The `helm test` script |
| ServiceAccount | `jenkins` | chart | The controller identity |
| Role | `jenkins-schedule-agents` | chart | Lets the controller create agent pods |
| Role | `jenkins-casc-reload` | chart | Lets the controller reload JCasC |
| RoleBinding | `jenkins-schedule-agents` | chart | Binds the agent Role |
| RoleBinding | `jenkins-watch-configmaps` | chart | Binds the reload Role |

The chart renders a StatefulSet, not a Deployment. The PVC is a separate object, not a `volumeClaimTemplate`.

The chart also renders a `Secret` named `jenkins` for a generated admin password. Setting `controller.admin.existingSecret` suppresses it. This project sets it, so `jenkins-credentials` is the only Secret in the namespace.

The chart renders a `Pod` named `jenkins-ui-test-*` under a `helm.sh/hook: test-success` annotation. A normal release does not install it.

### Ingress annotations

The Ingress carries the homepage annotations, in the pattern of `infra/roles/alertmanager/files/values.yaml`:

```yaml
traefik.ingress.kubernetes.io/router.tls: "true"
gethomepage.dev/enabled: "true"
gethomepage.dev/name: "Jenkins"
gethomepage.dev/group: "CI/Ops"
gethomepage.dev/icon: "jenkins"
gethomepage.dev/description: "Build pipelines"
```

`docs/homepage/homepage-project-plan.md` records Jenkins under CI/Ops with the annotation deferred "to when Ingress exists". This project closes that item.

### Secrets

Ansible Vault holds the source values. The role creates one Secret with `no_log: true`, in the pattern of `infra/roles/signal_bridge`.

| Vault variable | Use |
|---|---|
| `vault_jenkins_admin_password` | The local admin account |
| `vault_jenkins_github_pat` | Org folder scanning and repository checkout |
| `vault_jenkins_dockerhub_user` | Docker Hub push |
| `vault_jenkins_dockerhub_token` | Docker Hub push |

JCasC reads the values through the chart's additional-secrets mount. It never holds a literal.

**The GitHub PAT.** Use a classic token with the single scope `public_repo`. Every repository in the account is public, so the wider `repo` scope is not needed. `read:org` is not needed because the org folder scans a user account and not an organization. `user:email` is not needed because the security realm is the local user database. Neither `admin:repo_hook` nor `admin:org_hook` is needed because this project takes no webhooks.

Do not use a fine-grained token. The `github-branch-source` plugin reports an authorization failure as "0 repositories processed" and not as an error, which is difficult to diagnose.

**The mount.** The chart mounts the Secret at `/run/secrets/additional` and sets `SECRETS` to the same path. Each entry in `controller.additionalExistingSecrets` becomes one file named `<secret name>-<keyName>`. JCasC interpolates the file name:

```yaml
password: ${jenkins-credentials-github-pat}
```

**The admin password uses a different path.** Set `controller.admin.existingSecret` to `jenkins-credentials`, with `userKey` and `passwordKey` naming the keys in it. The chart then projects those keys to the fixed file names `chart-admin-username` and `chart-admin-password`, whatever the source keys are called. JCasC reads `${chart-admin-password}`. Do not add the admin keys to `additionalExistingSecrets` as well.

### Order of work

1. Verify the open items in section 3. Done.
2. Create the role, the values file, and the playbook. Deploy the controller alone.
3. Confirm the UI answers at `https://jenkins.houli.eu` and the blackbox probe passes.
4. Add the Kubernetes cloud and the DinD pod template. Confirm a pipeline runs `docker build`.
5. Add the credentials Secret and the JCasC credential entries.
6. Add the org folder. Confirm a job appears and pushes an image.
7. Add monitoring and the homepage entry.
8. Delete the local chart and retire the old home.

### Upgrades

1. Snapshot the PVC in Longhorn.
2. Change `jenkins_chart_version` in `defaults/main.yaml`.
3. Run the role.
4. Confirm the UI answers and one build passes.

A failed upgrade needs a chart version rollback and a role run. A corrupted `JENKINS_HOME` needs a PVC restore.

---

## 8. Decommission

### The local chart

Delete the `jenkins/` directory after the new deployment passes a build. It shares no object with the new release. The namespace, PV, and PVC names all differ.

### The old home

The export `/export/jenkins` on `lib-hp-01` stays on disk. Nothing references it after this project.

Archive it, then remove the NFS export through the OpenMediaVault UI. This is manual work on the OMV host, so the ticket is `ready-for-human`.

### TODO.md

The "Add jenkins agent" block is closed by this project:

- "Fix reverse proxy issue" — the `jenkinsUrl` setting in section 5.
- "Add pi, potato and nuc node labels" — already done. Every node carries `node_type` and `node_size`.
- "Move jenkins to pi node" — the placement in section 4.
- "Set executors to 0" — the chart default, kept.

---

## 9. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| A privileged DinD pod runs beside Longhorn on a pi | A container escape reaches the node and its storage | The pod runs in one namespace. Only Jenkins schedules it. Accepted for a homelab. |
| The Docker daemon accepts unauthenticated TCP | Any pod that reaches port 2375 gets root on the agent node | The daemon binds `127.0.0.1` through an explicit `--host` flag. Section 4 records it. |
| The daemon is not ready when its container starts | The first `docker` command in a build fails | Each pipeline waits for the daemon before its first `docker` command. |
| Docker deprecated the unencrypted API | A future `docker` image refuses to start the daemon | The image tag is pinned. Revisit at the next `docker` image bump. |
| A build exhausts memory on a 4 GB pi | The OOM killer takes the Longhorn instance-manager, not only the build | Memory limits on both agent containers. Anti-affinity from the controller. Concurrency of one. |
| pi-05 crashes during a build | The build fails | The node preference is soft. The next build lands elsewhere. |
| Images are `arm64` only | A future image cannot run on `lib-nuc-01` | Add a second pod template on the nuc, selected by an agent label. Not built now. |
| No layer cache | Builds are slow and pull base images each time | Accepted. The self-hosted registry in `TODO.md` is the real fix. |
| Plugin versions float at restart | An upgrade breaks Jenkins with no change in this repository | Pin the plugin list. Set `initializeOnce: true` once the install is stable. |
| Scan-based triggers | Up to 15 minutes between a push and a build | Accepted. No public endpoint is available. |

### Accepted without mitigation

1. Jenkins is offline during upgrades and node drains.
2. Build history is lost if the PVC is lost and no backup exists yet.
3. The org folder scans every repository in the account, including ones with no `Jenkinsfile`.

---

## 10. Milestones

### M0 — Verify

Complete. Ticket 01 answered the four items on 2026-08-27. Section 3 records the answers and the three corrections that followed.

### M1 — Controller

The role, the values file, and the playbook exist. The UI answers over HTTPS. Tickets 02 and 03.

### M2 — Agent

A pipeline runs on an agent pod and builds an image with the DinD sidecar. Tickets 04 and 05.

### M3 — Jobs

The org folder discovers the application repositories. A job pushes an image to Docker Hub. Ticket 06.

### M4 — Operate

Monitoring, the homepage entry, the runbook, and the decommission. Tickets 07, 08, and 09.
