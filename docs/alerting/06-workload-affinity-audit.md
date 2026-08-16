# Task: Audit and Update Workload Affinities for New Node Labels

Once nodes are relabelled with `node_size` (small/medium/large/x-large), update all existing Helm values files to use the new label instead of `node_type`.

## Roles to audit

| Role                  | Current affinity                              | Status |
|-----------------------|-----------------------------------------------|--------|
| `alertmanager`        | prefer `node_type=potato`, avoid `node_type=nuc` | pending |
| `grafana`             | check `files/values.yaml`                     | pending |
| `kube_state_metrics`  | check `files/values.yaml`                     | pending |
| `blackbox_exporter`   | check `files/values.yaml`                     | pending |
| `longhorn_chart`      | check `files/values.yaml`                     | pending |
| `metallb`             | check `files/values.yaml`                     | pending |
| `ntfy`                | set to prefer small/medium (new — see `ntfy-deploy.md`) | pending |
| `ntfy_bridge`         | set to prefer small/medium (new — see `ntfy-bridge-deploy.md`) | pending |
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
