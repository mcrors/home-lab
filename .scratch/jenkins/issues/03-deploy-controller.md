Status: ready-for-agent
Blocked by: 02

# M1: deploy the controller and verify the Ingress

## Context

The role exists. This ticket runs it for the first time and confirms Jenkins answers over HTTPS at the name Pi-hole already resolves.

See `docs/jenkins/jenkins-prd.md` section 7 (Deployment — Order of work, steps 2 and 3).

## Scope

1. Run the play: `ansible-playbook playbook.yaml --tags jenkins` from `infra/`.
2. Confirm the controller pod reaches `Running` and passes its readiness probe. First start installs plugins and is slow on a pi — allow several minutes.
3. Confirm the pod landed on a medium pi, not on pi-05 and not on a potato.
4. Retrieve the initial admin password from the chart-generated Secret and log in. The Vault-backed admin account arrives in ticket 05.
5. Confirm `https://jenkins.houli.eu` serves the UI with a valid certificate from the `houli-eu-wildcard` wildcard.
6. Confirm Jenkins shows **no** "reverse proxy setup is broken" warning under Manage Jenkins. If it appears, `jenkinsUrl` is wrong.
7. Confirm the Longhorn volume is bound and healthy.
8. Confirm the existing blackbox probe of `https://jenkins.houli.eu/login` now passes in Prometheus.
9. Run the play a second time and confirm it reports no change.

## Notes

- `infra/roles/prometheus/templates/prometheus.yml.j2` already lists the login URL. No monitoring change is needed for the probe to pass.
- Record the node the controller landed on. Ticket 04 needs it for the anti-affinity check.

## Acceptance criteria

- `kubectl get pods -n jenkins` shows one `Running` controller.
- The UI answers over HTTPS with the wildcard certificate and no browser warning.
- No reverse proxy warning appears in Manage Jenkins.
- `kubectl get pvc -n jenkins` shows a bound 8Gi Longhorn volume.
- The blackbox probe for `jenkins.houli.eu` reports success.
- A second run of the play is idempotent.
