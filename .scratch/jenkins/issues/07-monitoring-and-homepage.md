Status: ready-for-agent
Blocked by: 06

# M4: monitoring and the homepage entry

## Context

Jenkins is running and building. This ticket makes it visible in the tools that watch everything else.

See `docs/jenkins/jenkins-prd.md` section 7 (Ingress annotations) and `docs/alerting/README.md`.

## Scope

1. **Blackbox probe** — already configured in `infra/roles/prometheus/templates/prometheus.yml.j2`. Confirm it is green and no longer a standing failure. No change expected.
2. **Homepage** — confirm the six `gethomepage.dev/*` annotations from ticket 02 produce a Jenkins card in the CI/Ops group. `docs/homepage/homepage-project-plan.md` row HOM-04 records this as deferred "to when Ingress exists". Close that row.
3. **Uptime Kuma** — add an HTTP monitor for `https://jenkins.houli.eu/login`, notifying the `homelab-alerts` ntfy topic, matching the other service monitors.
4. **Longhorn backup** — add the `jenkins` PVC to the Longhorn backup target, as PRD section 6 (Data) requires. The signal-bridge project moved PVC backups to the Longhorn backups effort — follow whatever that effort settled on rather than inventing a second mechanism.
5. **Build failure notification** — decide whether a failed build should reach ntfy. If yes, the cheapest path is a `post { failure { ... } }` block posting to the ntfy server from the pipeline, not a Jenkins plugin. Record the decision in this file even if the answer is no.

## Notes

- Do not add the Jenkins Prometheus plugin unless a metric is actually wanted. The blackbox probe already answers "is it up", which is the question that matters for a build server that idles.

## Acceptance criteria

- The blackbox probe for `jenkins.houli.eu` is green in Prometheus.
- A Jenkins card appears on the homepage under CI/Ops.
- An Uptime Kuma monitor exists and reports up.
- The `jenkins` PVC is covered by the Longhorn backup target.
- The build-failure notification decision is recorded under `## Comments`.
