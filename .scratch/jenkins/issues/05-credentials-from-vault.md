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

The admin username is not a secret and stays out of the vault. It lives as `jenkins_admin_user` in `infra/roles/jenkins/defaults/main.yaml` and the Secret task reads it from there.

### Create the Secret from Ansible

Add a task to `infra/roles/jenkins/tasks/main.yaml`, before the Helm task, that creates a `jenkins-credentials` Secret in the `jenkins` namespace with `no_log: true`.

### Wire it into the chart

Ticket 01 confirmed the mechanism. The chart mounts the Secret at `/run/secrets/additional`, sets `SECRETS` to the same path, and names each file `<secret name>-<keyName>`.

- Add the three non-admin keys to `controller.additionalExistingSecrets`, one list entry per key. JCasC then interpolates the **file name**, for example `${jenkins-credentials-github-pat}`.
- Point `controller.admin.existingSecret` at `jenkins-credentials`, with `userKey` and `passwordKey` naming the admin keys in it. Setting `existingSecret` also stops the chart creating its own `jenkins` Secret, so `jenkins-credentials` is the only Secret in the namespace.
- The admin keys project to the **fixed** file names `chart-admin-username` and `chart-admin-password`, whatever the source keys are called. JCasC reads `${chart-admin-password}`.
- Do not also list the admin keys in `additionalExistingSecrets`. The `admin.existingSecret` path already mounts them.
- `name` and `keyName` must both be lowercase RFC 1123 labels.
- Leave `controller.admin.createSecret` at its default of `true`. Setting `existingSecret` is what stops the chart rendering its own Secret. `createSecret` separately gates the volume projection that mounts the admin keys, so setting it to `false` alongside `existingSecret` reads as correct and silently drops the mount, leaving the security realm with an unresolved `${chart-admin-username}` at startup. Confirmed against chart 5.9.54 on 2026-09-16.

### Declare the credentials in JCasC

Add two credential entries under `credentials.system.domainCredentials`:

- `github-pat` — username/password credential for the org folder
- `dockerhub` — username/password credential for image pushes

Both take their values from the mounted Secret. Neither holds a literal.

### Security realm

Set the JCasC security realm to the local user database with signup disabled and anonymous read denied, matching the old install's `FullControlOnceLoggedInAuthorizationStrategy` with `denyAnonymousReadAccess`.

This needs no code. The chart's JCasC defaults already render a local `securityRealm` with `allowsSignup: false`, and an `authorizationStrategy` of `loggedInUsersCanDoAnything` with `allowAnonymousRead: false`. The repo sets no JCasC values, so those defaults apply. Confirmed against chart 5.9.54 on 2026-09-16.

## Acceptance criteria

- Logging in with the Vault admin password succeeds.
- The chart generates no admin Secret of its own. `kubectl get secret -n jenkins` lists `jenkins-credentials` and no Secret named `jenkins`.
- Both credentials appear in Manage Jenkins with no plaintext in the UI or in git.
- `git grep` finds no token value anywhere in the repository.
- `kubectl get secret jenkins-credentials -n jenkins` shows five keys. The admin username occupies a key of its own. The chart's projection names that key explicitly, and a projected volume that names a key the Secret does not hold stops the pod from starting.
- Anonymous access to `https://jenkins.houli.eu` redirects to login.
- Running the role again is idempotent and logs no secret.

## Comments

### 2026-09-16 — admin password done

Deployed piecemeal, admin credential first. The role now applies a `jenkins-credentials` Secret holding `admin-user` and `admin-password`, and `controller.admin.existingSecret` points the chart at it. The GitHub and Docker Hub keys join the same task later.

Verified on the live cluster:

- Login with the vault password returns 200. A wrong password returns 401 and anonymous returns 403, so the 200 is real authentication.
- The projected files land as `chart-admin-username` and `chart-admin-password`. The username reads `admin` and the password file matches the vault value's length.
- `kubectl get secret -n jenkins` lists `jenkins-credentials` and no Secret named `jenkins`. Helm deleted the chart's own Secret on upgrade.
- The controller log holds no SEVERE or Exception line.
- `git grep` finds the password in no tracked file.

Not yet checked: the idempotent re-run. The next deploy exercises it anyway when the GitHub key goes in.
