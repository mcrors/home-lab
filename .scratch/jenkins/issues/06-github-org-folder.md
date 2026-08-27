Status: ready-for-agent
Blocked by: 05

# M3: add the GitHub org folder and build a real image

## Context

Jenkins now runs builds but knows about no repository. The org folder scans the GitHub account and creates one multibranch pipeline for each repository that holds a `Jenkinsfile`. This is what replaces the job definitions lost with the old `JENKINS_HOME`.

See `docs/jenkins/jenkins-prd.md` section 4 (Job discovery).

## Scope

### Declare the org folder in JCasC

Add a `jobs:` entry to the JCasC configuration that defines one GitHub Organization Folder:

- credential: `github-pat` from ticket 05
- scope: the `rhoulihan` GitHub account
- discovery: repositories that hold a `Jenkinsfile` at the root
- branch discovery: all branches, plus pull requests from origin
- orphaned item strategy: keep 10 builds, discard after 14 days
- scan trigger: every 15 minutes

No webhook. `jenkins.houli.eu` has no public DNS record, so GitHub cannot reach it. The timer is the only trigger.

### Point the pipelines at the agent

Each application `Jenkinsfile` must request the `docker` agent label from ticket 04. Confirm the `signal-bridge` repository's `Jenkinsfile` matches the pod template — it was written against the old install's DinD pattern and may reference a different label or a socket mount.

Each `Jenkinsfile` must also wait for the Docker daemon before its first `docker` command. The daemon needs approximately 17 seconds and the Kubernetes plugin does not wait for it:

```sh
timeout 120 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done'
```

Update the `Jenkinsfile` in the application repository if needed. That file lives in the application repository, not here.

### Verify with a real build

1. Trigger a scan. Confirm a job appears for `signal-bridge`.
2. Run the build. Confirm it pushes `rhoulihan/nfty-signal-bridge:<short-sha>` to Docker Hub.
3. Confirm the pushed image is `arm64`.
4. Confirm the cluster pulls the new tag — run a throwaway pod on a potato with the new tag.

Do not repoint the running `signal_bridge` role at the new tag in this ticket. That is a separate, deliberate change.

## Notes

- Never push a `latest` tag. The deployments reference exact SHA tags.
- If `arr-exporter` also holds a `Jenkinsfile`, it appears automatically. Confirm it builds, or record why it does not.
- The org folder scans every repository in the account. Repositories with no `Jenkinsfile` are skipped, not failed.

## Acceptance criteria

- The org folder exists after a controller restart, with no UI clicks.
- A job for `signal-bridge` appears from a scan.
- A build pushes an image to Docker Hub with a short-SHA tag and no `latest` tag.
- `docker manifest inspect` shows the pushed image is `arm64`.
- A pod on a potato pulls and starts the new tag.
- A commit pushed to the repository is picked up by the next scan, within 15 minutes.
