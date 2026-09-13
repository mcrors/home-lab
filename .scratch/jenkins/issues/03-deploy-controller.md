Status: resolved
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

## Answer

Deployed 2026-09-13. `ansible-playbook playbook.yaml --tags jenkins` from `infra/`, exit 0, `changed=2`. Helm release `jenkins` revision 1, chart `jenkins-5.9.54`, app version `2.568.2`.

**The controller runs on `lib-pi-01`** (`node_size=medium`, `node_type=pi`). Ticket 04 needs this for its anti-affinity check.

### Acceptance criteria

| Criterion | Result |
|---|---|
| One `Running` controller | pass, `jenkins-0` 2/2, 0 restarts |
| UI over HTTPS with the wildcard certificate | pass, `CN=*.houli.eu` from Let's Encrypt YR2, valid to 2026-11-14. `curl` without `-k` verifies the chain |
| No reverse proxy warning | pass, see below |
| Bound 8Gi Longhorn PVC | pass, `pvc-976f1727-7c34-455b-b2de-9f1308f5ecb8` |
| Blackbox probe reports success | pass, `probe_success=1`, `probe_http_status_code=200` |
| A second run is idempotent | pass, `changed=0`, helm still at revision 1 |

### Finding F — `/` answers 403, and the probe path was load-bearing

```
https://jenkins.houli.eu/       -> 403
https://jenkins.houli.eu/login  -> 200
```

The chart's default JCasC sets `allowAnonymousRead: false`, so an unauthenticated request to `/` gets a bare 403 rather than a redirect to the login page. The `http_2xx` module sets `follow_redirects: true`, which would have rescued a 302, but there is no redirect to follow.

Without the `prometheus.io/probe-path: /login` annotation that ticket 02 added under Finding E, the probe would be red right now and would have read as a broken deploy. The comment in `prometheus.yml.j2` that predicted this was correct.

Prometheus discovered the target exactly as the relabel chain predicted:

```
job=blackbox-ingress  instance=https://jenkins.houli.eu  namespace=jenkins  ingress=jenkins  probe_success=1
```

### How the reverse proxy check was verified

The string "It appears that your reverse proxy set up is broken" is present in the `/manage/` HTML whether or not the warning is showing. `ReverseProxySetupMonitor` renders its message into a hidden div, then tests client-side and only reveals it on failure. Grepping the page is therefore not a valid check.

Calling the monitor's own test endpoint the way the browser JS does:

```
GET /administrativeMonitor/hudson.diagnosis.ReverseProxySetupMonitor/test
  -> 302 to .../testForReverseProxySetup/https%3A%2F%2Fjenkins.houli.eu%2Fmanage%2F/
  -> 200
```

200 on the followed redirect means the test passes and the alert stays hidden. `controller.jenkinsUrl` did its job, which closes the "Fix reverse proxy issue" line in `TODO.md` (PRD section 8).

### The admin password

The chart generated it. Retrieve with:

```
kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
```

Username `admin`. The value is deliberately not recorded here. It survived the second run unchanged, confirming the `lookup` reuse in `_helpers.tpl:78` works under `helm upgrade`. Ticket 05 replaces it with the Vault-backed Secret.

Do not change this password in the Jenkins UI. The default JCasC reapplies `${chart-admin-password}` from the projected Secret at every startup, so a UI change reverts on the next restart.

### On the 15 minute timeout

First install completed in roughly 3 minutes, inside the 5m module default, so the timeout added before this deploy was not strictly needed. It stays. PRD section 6 says first start takes several minutes, this pi was otherwise idle, and the failure mode it guards against is a release stranded in `pending-install` that needs a manual `helm uninstall` before any retry.

### Note for future helm roles

The second run printed:

```
[WARNING]: The default idempotency check can fail to report changes in certain cases.
Install helm diff >= 3.4.1 for better results.
```

`changed=0` here is corroborated by the helm revision staying at 1, so the result is trustworthy for this run. The warning applies to every `kubernetes.core.helm` task in the repo, not just this one. Installing the `helm-diff` plugin on the control workstation would make the idempotency reporting reliable across all nine helm roles. Not done, and not part of this project.

### Left for a human

The two visual checks. The certificate chain verifies without `-k` and the reverse proxy monitor test returns 200, so both should be clean in a browser, but neither substitutes for loading the page.
