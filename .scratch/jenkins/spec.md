Status: ready-for-agent

# Jenkins on k3s

See `docs/jenkins/jenkins-prd.md` for the full specification.

## Decisions recorded outside the PRD

- Use the upstream `jenkinsci/jenkins` chart. Delete the local chart at `jenkins/`. Do not write a chart.
- The role lives in `infra/`, not `services/`. Jenkins is platform tooling and its credentials come from the `infra` vault.
- Agents are ephemeral pods, one at a time. No permanent agent Deployment. The controller keeps 0 executors.
- The DinD sidecar runs `privileged: true`. Rootless buildkit and kaniko were considered and rejected — existing Jenkinsfiles call `docker build` directly.
- Builds run native `arm64` on a pi. No QEMU. No multi-arch manifest. An `amd64` template on the nuc is a later addition, not part of this project.
- Jobs come from a GitHub org folder, not from Job DSL and not from the UI. A repository with a `Jenkinsfile` becomes a job by itself.
- No webhooks. `jenkins.houli.eu` has no public DNS record. The org folder rescans every 15 minutes instead.
- Every repository in the GitHub account is public and stays public. The scanning PAT is a classic token with the single scope `public_repo`. A fine-grained token is not used — the plugin reports an authorization failure as "0 repositories processed".
- The DinD daemon binds `127.0.0.1` through an explicit `--host` flag. The image default binds every interface in the pod, which would expose a root-equivalent socket to the whole cluster.
- Nothing migrates from the old `JENKINS_HOME` on `lib-hp-01`. Its `jobs/` directory is empty. Start clean.
- Build history has no backup until the PVC joins the Longhorn backup target. Accepted for the first deploy.
