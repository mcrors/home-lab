# Task: Audit and Update Workload Affinities for New Node Labels ✅ DONE (2026-08-22)

Once nodes are relabelled with `node_size` (small/medium/large/x-large), update all existing Helm values files to use the new label instead of `node_type`.

## Roles to audit

| Role                  | Current affinity                              | Status |
|-----------------------|-----------------------------------------------|--------|
| `alertmanager`        | prefer `node_size=small`, avoid `x-large`     | done |
| `grafana`             | `required: node_size In [x-large]`            | done |
| `kube_state_metrics`  | prefer `node_size=small`, avoid `x-large`     | done |
| `blackbox_exporter`   | prefer `node_size=small`, avoid `x-large`     | done |
| `longhorn_chart`      | no affinity set                               | done |
| `metallb`             | controller prefer `node_size=small`           | done |
| `ntfy`                | prefer medium, required NotIn small/x-large (Longhorn dependency) | done |
| `ntfy_bridge`         | prefer small/medium, avoid large/x-large      | done |
| `prowlarr`            | `required: node_size In [medium, large]`      | done |
| `radarr`              | `required: node_size In [medium, large]`      | done |
| `sonarr`              | `required: node_size In [medium, large]`      | done |
| `uptime-kuma`         | `required: node_size In [medium, large]`      | done |

## For each role

Replace `node_type`-based affinity with `node_size`-based equivalents. General guidance:
- Most monitoring/infra workloads: prefer `small` or `medium`, avoid `x-large` (reserve for compute-heavy)
- Storage-adjacent workloads: check whether they need to co-locate with specific node types

## Cleanup

Once all roles are updated and deployed, remove the old `node_type` labels from nodes.

## Dependencies

- `node-relabeling.md` must be complete first
