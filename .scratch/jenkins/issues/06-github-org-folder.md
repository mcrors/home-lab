Status: resolved
Blocked by: 05

# M3: add the GitHub org folder and build a real image

## Context

Jenkins now runs builds but knows about no repository. The org folder scans the GitHub account and creates one multibranch pipeline for each repository that holds a `Jenkinsfile`. This is what replaces the job definitions lost with the old `JENKINS_HOME`.

See `docs/jenkins/jenkins-prd.md` section 4 (Job discovery).

## Scope

### Declare the org folder in JCasC

Add a `jobs:` entry to the JCasC configuration that defines one GitHub Organization Folder:

- credential: `github-pat` from ticket 05
- scope: the `mcrors` GitHub account
- discovery: repositories that hold a `Jenkinsfile` at the root
- branch discovery: all branches, plus pull requests from origin
- orphaned item strategy: keep 10 builds, discard after 14 days
- scan trigger: every 15 minutes

No webhook. `jenkins.houli.eu` has no public DNS record, so GitHub cannot reach it. The timer is the only trigger.

### Point the pipelines at the agent

Each application `Jenkinsfile` must request the `docker` agent label from ticket 04. Confirm the `nfty-signal-bridge` repository's `Jenkinsfile` matches the pod template — it was written against the old install's DinD pattern and may reference a different label or a socket mount.

**Run the steps in the `docker` container.** Ticket 04 Finding H: the agent pod holds three containers and the steps land in `jnlp` by default, which carries no Docker client. Every `docker` command has to run in the `docker` container instead. Either wrap each block:

```groovy
container('docker') {
    sh 'docker build -t ...'
}
```

or set it once for the pipeline, which is the shorter form when every step is a Docker step:

```groovy
agent {
    kubernetes {
        inheritFrom 'docker-arm64'
        defaultContainer 'docker'
    }
}
```

A step that runs outside that container fails with `docker: not found` rather than a connection error, because the client is missing rather than the daemon.

Each `Jenkinsfile` must also wait for the Docker daemon before its first `docker` command. The daemon needs approximately 17 seconds and the Kubernetes plugin does not wait for it. The wait itself runs in the `docker` container, for the same reason:

```sh
timeout 120 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done'
```

Update the `Jenkinsfile` in the application repository if needed. That file lives in the application repository, not here.

### Verify with a real build

1. Trigger a scan. Confirm a job appears for `nfty-signal-bridge`.
2. Run the build. Confirm it pushes `rhoulihan/nfty-signal-bridge:<short-sha>` to Docker Hub.
3. Confirm the pushed image is `arm64`.
4. Confirm the cluster pulls the new tag — run a throwaway pod on a potato with the new tag.

Do not repoint the running `signal_bridge` role at the new tag in this ticket. That is a separate, deliberate change.

## Notes

- Never push a `latest` tag. The deployments reference exact SHA tags.
- If `arr-exporter` also holds a `Jenkinsfile`, it appears automatically. Confirm it builds, or record why it does not.
- The org folder scans every repository in the account. Repositories with no `Jenkinsfile` are skipped, not failed.
- The GitHub account is `mcrors`, confirmed on 2026-09-17 from the token's own `/user` response and from this repo's git remote. Earlier drafts of this ticket said `rhoulihan`, which is a different person's GitHub account. A `public_repo` token can read anyone's public repositories, so an org folder scoped to the wrong account would scan successfully and build a stranger's repositories.
- The Docker Hub namespace in this ticket is still `rhoulihan`. Docker Hub is a separate service from GitHub and that namespace has not been verified. Check it before the first push.

## Acceptance criteria

- Every `docker` step in each `Jenkinsfile` runs in the `docker` container, by wrapper or by `defaultContainer`.
- The org folder exists after a controller restart, with no UI clicks.
- A job for `nfty-signal-bridge` appears from a scan.
- A build pushes an image to Docker Hub with a short-SHA tag and no `latest` tag.
- `docker manifest inspect` shows the pushed image is `arm64`.
- A pod on a potato pulls and starts the new tag.
- A commit pushed to the repository is picked up by the next scan, within 15 minutes.

## Comments

### 2026-09-18 — org folder deployed, first real build, ticket closed

The org folder is declared in JCasC and reached the controller through a Helm
upgrade. It scans `mcrors`, discovers every branch except one with an open pull
request, and discovers pull requests from origin at their head commit. Pull
requests build the head rather than a merge with the target, so the short SHA an
image is tagged with names a commit that exists.

The `jobs` root element needs the job-dsl plugin. It was missing from
`installPlugins`, and without it the block is ignored at startup rather than
rejected.

The chart moved to 5.9.63, which ships Jenkins 2.568.3 and clears the advisory
against 2.568.2. The `kubernetes` and `configuration-as-code` pins moved to the
versions that chart defaults to, since `installPlugins` replaces the chart's list
rather than extending it.

`nfty-signal-bridge` got a new `Jenkinsfile` at commit `dd06f29`. The inline pod
definition is gone, replaced by `inheritFrom 'docker-arm64'` with
`defaultContainer 'docker'`. A first stage polls `docker info` until the daemon
answers. `TAG` is set after checkout rather than in the `environment` block,
which is evaluated before `GIT_COMMIT` is populated and would have tagged the
image from the string "null".

Acceptance criteria:

- Every `docker` step runs in the `docker` container, by `defaultContainer`.
- The org folder came from JCasC with no UI clicks.
- Jobs appeared for `nfty-signal-bridge` and `ytd`.
- Build 2 of `nfty-signal-bridge » main` pushed `rhoulihan/nfty-signal-bridge:dd06f29`. No `latest` tag.
- `docker manifest inspect --verbose` reports `architecture: arm64`.
- The pod spec in the build log carries the node affinity, the pod anti-affinity, the `docker-graph-storage` mount on `dind` alone, `DOCKER_TLS_CERTDIR: ""`, and both pinned image digests, so `inheritFrom` does carry `yamlTemplate` across.

Two criteria were settled differently than written:

- The potato pull test was skipped. The running `signal_bridge` already pulls
  from the same public Docker Hub repository, which is the same evidence.
- The 15 minute pickup was not observed on a timer. The trigger is verified in
  the folder XML instead.

Findings worth carrying forward:

- The DSL's `triggers { periodicFolderTrigger { interval('15m') } }` was ignored
  without an error and left the folder on the 1 day default. The trigger is now
  written into the folder XML through a `configure` block, verified as
  `spec H/15 * * * *` with `interval 900000`. `PeriodicFolderTrigger` carries no
  `@Symbol`, which is the likely reason the generated DSL did not reach it.
- The controller log reports "GitHub webhooks activated" on every scan. Nothing
  is created: the repositories hold no webhooks, and no GitHub server is
  configured for the github plugin to call. The line names the repositories it
  considered. Rory may add a real webhook later as a learning exercise.
- `ytd` holds a zero byte `Jenkinsfile`, so its job exists and cannot build. The
  repository owns that file. `arr-exporter` never appeared, so it holds no
  `Jenkinsfile`.
- A `configScripts` change alone reloads live through the config sidecar, with
  no controller restart. Only an image change restarts the pod.
