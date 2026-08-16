# Task: Upgrade Longhorn from v1.11.0 to v1.11.2

Upgrade Longhorn to v1.11.2 to permanently fix the proxy connection leak in the
instance-manager that caused lib-nuc-01 to grow from 20GB to 47GB of memory over ~7 weeks.

## Background

Longhorn v1.11.0 has a known regression (issue [#12575](https://github.com/longhorn/longhorn/issues/12575))
where proxy connections in the instance-manager are never closed. The instance-manager acts as a
proxy between volume engines and their replicas — on lib-nuc-01, which hosts all 6 volume engines,
this caused 2,168 leaked sockets and 46.3GB of heap accumulation over 50 days (~100MB/day).

Pi nodes were unaffected because they only run replicas, not engines, and don't go through the
proxy path.

v1.11.1 fixed the leak. v1.11.2 additionally optimised longhorn-manager's informer caching to
reduce its own memory footprint. v1.11.3 is not suitable — it requires Kubernetes ≥1.34 and the
cluster is on v1.32.

## Compatibility

- v1.11.2 requires Kubernetes ≥1.25 — cluster is on v1.32.13 ✓
- Upgrade path from v1.11.0 → v1.11.2 is supported ✓

## Steps

**1. Update image tags in values.yaml**

File: `infra/roles/longhorn_chart/files/values.yaml`

Change all `v1.11.0` tags to `v1.11.2`:

```yaml
image:
  longhorn:
    engine:
      tag: v1.11.2
    manager:
      tag: v1.11.2
    ui:
      tag: v1.11.2
    instanceManager:
      tag: v1.11.2
    shareManager:
      tag: v1.11.2
    backingImageManager:
      tag: v1.11.2
```

Leave the CSI sidecar tags unchanged — they are not Longhorn-versioned.

**2. Run the Ansible playbook**

```bash
cd infra
workon ansible
ansible-playbook playbooks/k3s.yaml -i inventory.yaml --tags longhorn
```

**3. Watch the rollout**

```bash
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
kubectl get pods -n longhorn-system -w
```

Wait for all pods to show the new image version before proceeding.

## Validation

```bash
kubectl get pods -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' | grep longhorn
# All longhornio images should show v1.11.2

kubectl get volumes.longhorn.io -n longhorn-system
# All volumes should be detached and healthy (not faulted)
```

## Dependencies

- Task 01 (scale down workloads) must be complete — all volumes detached before upgrading.
