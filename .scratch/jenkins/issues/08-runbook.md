Status: ready-for-agent
Blocked by: 07

# M4: write the operating runbook

## Context

Every other subsystem in this repository has a README that holds its operating procedures — see `docs/alerting/README.md`. Jenkins needs the same before this project closes.

## Scope

Write `docs/jenkins/README.md` covering:

1. **Deploy** — the one-line play, in the shape of the Deploy section in `docs/alerting/README.md`.
2. **Upgrade the chart** — snapshot the PVC, bump `jenkins_chart_version`, run the role, confirm one build. Include the rollback.
3. **Upgrade plugins** — how the pinned list works, and how to flip `controller.initializeOnce` to `true`. **Do this flip as part of this ticket** once the install is proven stable, so restarts stop re-resolving plugin versions.
4. **Rotate credentials** — the GitHub PAT and the Docker Hub token, both through the vault and the role.
5. **Recover from a lost PVC** — what returns by itself (all system configuration, the org folder, and every job the org folder rediscovers) and what does not (build history and artifacts).
6. **Add a new pipeline** — push a `Jenkinsfile` to a repository, wait for the scan or trigger it. No Jenkins-side work.
7. **Add an amd64 build path** — the escape hatch from PRD section 9: a second pod template on `lib-nuc-01` selected by an agent label. Sketch it, do not build it.
8. **Troubleshooting** — agent pod stuck pending (concurrency cap of 1, or anti-affinity with no free pi), `docker version` failing in a build (the `dind` sidecar lost the race), and the reverse proxy warning returning (`jenkinsUrl` drift).

## Acceptance criteria

- `docs/jenkins/README.md` exists and covers all eight topics.
- Every command in it has been run at least once against the live cluster.
- `controller.initializeOnce` is `true` and a controller restart no longer re-resolves plugin versions.
