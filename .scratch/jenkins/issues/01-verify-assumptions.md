Status: resolved

# M0: verify the four open assumptions

## Context

Four facts are unconfirmed. Each one changes the implementation if it turns out false. Confirm all four before writing the role.

See `docs/jenkins/jenkins-prd.md` section 3 (Feasibility — Unverified).

## Scope

### 1. arm64 images

Confirm each image publishes an `arm64` manifest for the tag the role will pin:

- `jenkins/jenkins:<lts-jdk21 tag matching chart 5.9.54 appVersion 2.568.2>`
- `jenkins/inbound-agent:3385.vf1123fb_515da_-1`
- `docker:28-dind`

Use `docker manifest inspect` or the registry API. Record the resolved digests.

### 2. Privileged pod admission

Confirm k3s admits a privileged pod in a new `jenkins` namespace with no policy change. Run a throwaway pod with `securityContext.privileged: true` and confirm it reaches `Running`. Delete it afterwards.

If admission is refused, record the exact error. The fix is a PodSecurity label on the namespace, and it changes ticket 02.

### 3. Additional-secrets mount path

Confirm how chart 5.9.54 exposes `controller.additionalExistingSecrets` to JCasC. Render the chart locally:

```bash
helm template jenkins jenkinsci/jenkins --version 5.9.54 -f <test values>
```

Record the mount path, the `SECRETS` environment variable, and the exact JCasC interpolation syntax for a key. Ticket 05 depends on this answer.

### 4. GitHub token scopes

Determine the minimum PAT scopes the `github-branch-source` plugin needs to scan the account and check out repositories. Record whether a classic token or a fine-grained token is required.

## Notes

- Do not deploy anything in this ticket. Rendering and throwaway pods only.
- The cluster is reachable with `kubectl` from the workstation.

## Acceptance criteria

- All four answers are appended to this file under `## Answer`.
- Resolved image digests are recorded for the three images.
- The privileged pod test result is recorded, with the error text if it failed.
- The JCasC interpolation syntax is recorded as a copy-pasteable example.
- No object is left behind in the cluster.

## Answer

Verified 2026-08-27. All four assumptions hold. Three findings change later tickets. They are marked **Finding**.

### 1. arm64 images — confirmed

Chart 5.9.54 does not pin a controller tag. `controller.image.tag` is empty and `controller.image.tagLabel` is `jdk21`. The helper at `templates/_helpers.tpl:641` builds the tag as `<appVersion>-<tagLabel>`. The resolved tag is therefore `jenkins/jenkins:2.568.2-jdk21`. The role does not need to set the tag.

All three images publish a `linux/arm64` manifest.

| Image | arm64 manifest digest | Index (tag) digest |
|---|---|---|
| `jenkins/jenkins:2.568.2-jdk21` | `sha256:5cb5f0c8b4170532150d48ca076b38cd68fd22a2d818c52b209d14e331d0f870` | `sha256:8547df3b0db2803d158ecc9499207a056bb30c23fddc18bb5b4a4dc14e77dd09` |
| `jenkins/inbound-agent:3385.vf1123fb_515da_-1` | `sha256:900a5bfce7b54ca7d92db097e6f4362c442a0ba6bd36bd96d518719e2e55de2e` | `sha256:6dbeabd484bb3926293de0b337117f7ad8bb2c0ba1a425b3e34e3d3983b5e1f9` |
| `docker:28-dind` | `sha256:145184796e8717376e73eaf29e16ede8ede2fd75e947a3fae7c05298e5e20d28` (`arm64/v8`) | `sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac` |

`jenkins/inbound-agent:3385.vf1123fb_515da_-1` is the chart default at `values.yaml:1024`. The role does not need to set it.

### 2. Privileged pod admission — confirmed, no policy change needed

Static evidence:

1. No namespace carries a `pod-security.kubernetes.io/*` label. All 19 namespaces have none.
2. The `PodSecurityPolicy` API does not exist on this cluster.
3. No `ValidatingAdmissionPolicyBinding` exists.
4. The only validating webhooks are `cert-manager`, `frr-k8s`, `longhorn`, and `metallb`. None filters pod security.
5. `longhorn-system` already runs privileged containers on every node.

Live test. Namespace `jenkins-verify-01` held pod `dind-probe`, pinned to `lib-pi-05`, with `docker:28-dind` at `privileged: true` and a `docker:28-cli` sidecar. The pod was admitted with no error and reached `Running` 2/2.

The test also proved the section 4 agent design end to end:

```
docker info  -> Server=28.5.2 Arch=aarch64 OS=Alpine Linux v3.22 (containerized) Driver=overlay2
docker build -> built-arch=arm64
docker run   -> hello-from-dind
```

The client container reached the daemon at `tcp://localhost:2375` with no socket mount and no TLS.

The namespace was deleted. `kubectl get ns` shows no `jenkins*` namespace and no probe pod.

**Finding A — the daemon is not ready when the container starts. Affects ticket 04.**

`dockerd` logged `Daemon has completed initialization` 17 seconds after the container start time. An exec at 13 seconds failed:

```
Cannot connect to the Docker daemon at tcp://localhost:2375. Is the docker daemon running?
```

The Kubernetes plugin waits for the container to start, not for the daemon to accept connections. A pipeline that calls `docker` in its first step fails intermittently. Ticket 04 must add a wait, either in the pod template command or at the top of the `Jenkinsfile`:

```sh
timeout 120 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done'
```

**Finding B — the daemon does not bind loopback. Affects the PRD and ticket 04.**

The daemon logged `API listen on [::]:2375`, not a loopback address. PRD section 4 says "The listener binds to the pod only" and section 6.Security item 5 says "The Docker daemon listens on the pod loopback address only". Both statements are wrong for the default `docker:28-dind` entrypoint with an empty `DOCKER_TLS_CERTDIR`.

The daemon binds every interface in the pod network namespace, which includes the pod IP. Any pod in the cluster can therefore reach `<agent-pod-ip>:2375`, and access to that port is root-equivalent on the agent's node. Cross-pod reachability was not tested — this is read from the bind address in the log, which is sufficient to disprove "loopback only".

Two fixes, either is enough:

1. Override the dind args to bind loopback: `--host=tcp://127.0.0.1:2375`. Then set `DOCKER_HOST=tcp://127.0.0.1:2375` on the `jnlp` container.
2. Add a default-deny ingress `NetworkPolicy` in the `jenkins` namespace.

Option 1 is preferred. It needs no CNI policy support and it makes the PRD statement true.

The daemon also logged a deprecation notice: an unencrypted API "will be a hard failure preventing the daemon from starting" in a future version. Option 1 does not clear this. Record it against the `docker` image pin.

### 3. Additional-secrets mount path — confirmed

Rendered with `helm template jenkins jenkinsci/jenkins --version 5.9.54 -n jenkins -f <values>`.

| Item | Value |
|---|---|
| Mount path | `/run/secrets/additional` |
| Environment variable | `SECRETS=/run/secrets/additional` |
| File name for a key | `<secret name>-<keyName>` |
| Volume | projected, one source per list entry, `readOnly: true` |

The mount appears when any of `additionalSecrets`, `existingSecret`, `additionalExistingSecrets`, or `admin.createSecret` is set.

Copy-pasteable example. These values:

```yaml
controller:
  additionalExistingSecrets:
    - name: jenkins-credentials
      keyName: github-pat
    - name: jenkins-credentials
      keyName: dockerhub-token
```

produce the files `/run/secrets/additional/jenkins-credentials-github-pat` and
`/run/secrets/additional/jenkins-credentials-dockerhub-token`, and JCasC reads them as:

```yaml
credentials:
  system:
    domainCredentials:
      - credentials:
          - usernamePassword:
              scope: GLOBAL
              id: github-pat
              username: rhoulihan
              password: ${jenkins-credentials-github-pat}
          - usernamePassword:
              scope: GLOBAL
              id: dockerhub
              username: ${jenkins-credentials-dockerhub-user}
              password: ${jenkins-credentials-dockerhub-token}
```

The interpolation key is the file name, not the Kubernetes key name. `name` and `keyName` must both be lowercase RFC 1123 labels.

The admin password uses a different path. Set `controller.admin.existingSecret` and the chart stops creating its own Secret — `templates/secret.yaml:1` is guarded by `and (not .Values.controller.admin.existingSecret) (.Values.controller.admin.createSecret)`. The projected file names are fixed at `chart-admin-username` and `chart-admin-password` whatever the source keys are called. So:

```yaml
controller:
  admin:
    existingSecret: jenkins-credentials
    userKey: admin-user
    passwordKey: admin-password
```

gives JCasC `${chart-admin-password}`. One Secret then carries all four Vault values, which matches the object table in PRD section 7.

**Finding C — the PRD object table is wrong. Affects ticket 02.**

The chart renders a `StatefulSet`, not a `Deployment`. PRD section 7 lists "Deployment | jenkins | chart". The table also misses four objects. The full rendered set is:

| Kind | Name |
|---|---|
| ServiceAccount | `jenkins` |
| ConfigMap | `jenkins` |
| ConfigMap | `jenkins-jenkins-jcasc-config` |
| PersistentVolumeClaim | `jenkins` |
| Role | `jenkins-schedule-agents` |
| Role | `jenkins-casc-reload` |
| RoleBinding | `jenkins-schedule-agents` |
| RoleBinding | `jenkins-watch-configmaps` |
| Service | `jenkins` |
| Service | `jenkins-agent` |
| StatefulSet | `jenkins` |
| ConfigMap | `jenkins-tests` |

`Secret jenkins` renders only when `admin.existingSecret` is empty. `Pod jenkins-ui-test-*` is a `helm test` hook and is not installed by a normal release. No Ingress renders until `controller.ingress.enabled` is set.

The PVC is a separate object, not a `volumeClaimTemplate`, so the `Recreate`-style behaviour in PRD section 6 comes from the StatefulSet update strategy, not from a Deployment strategy. Ticket 02 must not set `strategy: Recreate`.

### 4. GitHub token scopes

Use a **classic** PAT. The plugin's documented permission model is expressed in classic scopes, and fine-grained tokens fail silently — the plugin reports "0 repositories processed" for an authorization failure rather than an error, which is hard to diagnose.

The homelab account is a personal user account, not an organization. The org folder scans a user. That removes two scopes from the usual list.

| Scope | Needed? | Reason |
|---|---|---|
| `public_repo` | **yes** | Discovery and checkout of a public repository. Also covers commit status. |
| `repo` | no | Full control of private repositories. Every repository in the account is public. |
| `read:org` | no | Organization membership only. Not used when scanning a user account. |
| `user:email` | no | For the GitHub Authentication plugin. This project uses the local user database. |
| `admin:repo_hook` | no | Repository webhook management. PRD section 2 non-goal 3. |
| `admin:org_hook` | no | Organization webhook management. Not applicable and not a goal. |

**Minimum: `public_repo` alone.**

The account holds only public repositories. This is a standing decision, confirmed 2026-08-27, not an observation of the two current repositories. If a private repository ever needs a build, the scope widens to `repo`.

The credential is a `usernamePassword` with the GitHub username as username and the PAT as password. That is the form the org folder expects for scan credentials.

A GitHub App is the more secure option and is what the plugin now recommends. It is not adopted here: it needs a public callback for installation management and it adds a private key to Vault. PRD section 7 already fixes the PAT design. Record the App as a later improvement, not a change to this project.

Sources: [CloudBees — GitHub permissions and PAT scopes for Jenkins](https://docs.cloudbees.com/docs/cloudbees-ci-kb/latest/client-and-managed-controllers/github-user-scopes-and-organization-permissions-overview), [GitHub Docs — Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), [Jenkins — GitHub App authentication support released](https://www.jenkins.io/blog/2020/04/16/github-app-authentication/), [github-branch-source-plugin issue #1493](https://github.com/jenkinsci/github-branch-source-plugin/issues/1493).

### Cluster state

No object left behind. Namespace `jenkins-verify-01` deleted, `jenkins` namespace still absent, deploy still starts clean.
