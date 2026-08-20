# Task: Permanently Fix Longhorn Webhook Timeout

Status: DONE

The Longhorn admission webhook (`longhorn-webhook-validator`) has `failurePolicy: Fail`.
PVC creation intermittently fails with a context deadline exceeded error when the apiserver
cannot reach the webhook service in time. This has blocked at least one PVC creation in
the cluster (ntfy, Aug 2026).

## Root cause

k3s routes apiserver → webhook traffic through flannel (its embedded CNI). When the
`longhorn-manager` pods backing the webhook are on different nodes from the k3s server
process, the cross-node hop can drop or delay packets beyond the apiserver's 10-second
webhook timeout. This is a recurring k3s/Longhorn interaction tracked across multiple
upstream issues (longhorn/longhorn #5327, #6017, #6464) with no single version fix.

## Observed error

```
Error saving claim: Internal error occurred: failed calling webhook "validator.longhorn.io":
failed to call webhook: Post "https://longhorn-admission-webhook.longhorn-system.svc:9502/v1/webhook/validation?timeout=10s":
context deadline exceeded
```

The webhook service and its endpoints (backed by `longhorn-manager` pods) appeared healthy —
`kubectl get endpoints longhorn-admission-webhook -n longhorn-system` showed 5 endpoints.
The issue is network-level, not pod-level.

## Workaround applied (Aug 2026)

Temporarily patched to `failurePolicy: Ignore`, deleted and recreated the stuck PVC, then
patched back to `Fail`. This is not persistent — Longhorn upgrades will reset the value.

## Recommended permanent fix

Set `failurePolicy: Ignore` permanently. Longhorn maintainers explicitly acknowledge this
trade-off: invalid PVC requests will be rejected later at the controller level rather than
at admission. No data loss risk. Widely recommended for homelab/non-production clusters.

Apply via the Longhorn Helm values in the Ansible role so it survives upgrades:

```bash
# Check if Longhorn Helm chart exposes this value
helm show values longhorn/longhorn | grep -i webhook
```

If not exposed (it wasn't as of v1.6/v1.7), apply a post-install patch in the Ansible role:

```yaml
- name: Patch Longhorn webhook failurePolicy to Ignore
  kubernetes.core.k8s_json_patch:
    api_version: admissionregistration.k8s.io/v1
    kind: ValidatingWebhookConfiguration
    name: longhorn-webhook-validator
    patch:
      - op: replace
        path: /webhooks/0/failurePolicy
        value: Ignore
```

Add this task to `infra/roles/longhorn/tasks/main.yaml` after the Helm install/upgrade task.

## Alternative: disable webhooks entirely

Longhorn v1.5+ supports disabling the admission webhook entirely via a manager flag. More
aggressive than `failurePolicy: Ignore` but a clean permanent solution:

```yaml
# In Longhorn Helm values
longhornManager:
  additionalArgs:
    - --disable-admission-webhook
```

Trade-off: loses all admission validation (bad PVC parameters fail at the controller, not
at apply time). Acceptable for a homelab where PVC changes are infrequent and deliberate.

## Implementation steps

1. Check current Longhorn Helm values in `infra/roles/longhorn/` for an existing webhook knob
2. Add the post-install patch task to the Longhorn Ansible role (preferred)
3. Run `ansible-playbook playbooks/observability.yaml --tags longhorn` to apply
4. Verify: `kubectl get validatingwebhookconfiguration longhorn-webhook-validator -o jsonpath='{.webhooks[0].failurePolicy}'` → should return `Ignore`

## Dependencies

Independent — can be done at any time. Should be applied before the next Longhorn upgrade
to prevent the manual workaround from being needed again.
