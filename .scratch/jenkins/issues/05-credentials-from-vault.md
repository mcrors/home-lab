Status: ready-for-human
Blocked by: 04

# M2: move credentials into Ansible Vault

## Context

Jenkins needs three secrets: the admin password, a GitHub PAT for repository scanning, and a Docker Hub token for pushes. Ansible Vault holds the source values. JCasC reads them from a mounted Secret.

This ticket is `ready-for-human` because it needs the vault password and new tokens created in GitHub and Docker Hub.

See `docs/jenkins/jenkins-prd.md` section 7 (Secrets) and the pattern in `infra/roles/signal_bridge/tasks/main.yaml`.

## Scope

### Create the tokens

1. A GitHub PAT. Use a **classic** token with the single scope `public_repo`. Every repository in the account is public. Do not use a fine-grained token — the plugin reports an authorization failure as "0 repositories processed" rather than as an error. Ticket 01 records why each other scope is unnecessary.
2. A Docker Hub access token with write access to the `rhoulihan` namespace.
3. A strong admin password.

### Add them to the vault

Add four variables to `infra/group_vars/all/vault.yaml`:

- `vault_jenkins_admin_password`
- `vault_jenkins_github_pat`
- `vault_jenkins_dockerhub_user`
- `vault_jenkins_dockerhub_token`

### Create the Secret from Ansible

Add a task to `infra/roles/jenkins/tasks/main.yaml`, before the Helm task, that creates a `jenkins-credentials` Secret in the `jenkins` namespace with `no_log: true`.

### Wire it into the chart

Ticket 01 confirmed the mechanism. The chart mounts the Secret at `/run/secrets/additional`, sets `SECRETS` to the same path, and names each file `<secret name>-<keyName>`.

- Add the three non-admin keys to `controller.additionalExistingSecrets`, one list entry per key. JCasC then interpolates the **file name**, for example `${jenkins-credentials-github-pat}`.
- Point `controller.admin.existingSecret` at `jenkins-credentials`, with `userKey` and `passwordKey` naming the admin keys in it. Setting `existingSecret` also stops the chart creating its own `jenkins` Secret, so `jenkins-credentials` is the only Secret in the namespace.
- The admin keys project to the **fixed** file names `chart-admin-username` and `chart-admin-password`, whatever the source keys are called. JCasC reads `${chart-admin-password}`.
- Do not also list the admin keys in `additionalExistingSecrets`. The `admin.existingSecret` path already mounts them.
- `name` and `keyName` must both be lowercase RFC 1123 labels.

### Declare the credentials in JCasC

Add two credential entries under `credentials.system.domainCredentials`:

- `github-pat` — username/password credential for the org folder
- `dockerhub` — username/password credential for image pushes

Both take their values from the mounted Secret. Neither holds a literal.

### Security realm

Set the JCasC security realm to the local user database with signup disabled and anonymous read denied, matching the old install's `FullControlOnceLoggedInAuthorizationStrategy` with `denyAnonymousReadAccess`.

## Acceptance criteria

- Logging in with the Vault admin password succeeds.
- The chart generates no admin Secret of its own. `kubectl get secret -n jenkins` lists `jenkins-credentials` and no Secret named `jenkins`.
- Both credentials appear in Manage Jenkins with no plaintext in the UI or in git.
- `git grep` finds no token value anywhere in the repository.
- `kubectl get secret jenkins-credentials -n jenkins` shows four keys.
- Anonymous access to `https://jenkins.houli.eu` redirects to login.
- Running the role again is idempotent and logs no secret.
