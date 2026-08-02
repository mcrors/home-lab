# Task: Audit and Update Workload Affinities for New Node Labels

Once nodes are relabelled with `node_size` (small/medium/large/x-large), update all existing Helm values files to use the new label instead of `node_type`.

## Roles to audit

| Role                  | Current affinity                              |
|-----------------------|-----------------------------------------------|
| `alertmanager`        | prefer `node_type=potato`, avoid `node_type=nuc` |
| `grafana`             | check `files/values.yaml`                     |
| `kube_state_metrics`  | check `files/values.yaml`                     |
| `blackbox_exporter`   | check `files/values.yaml`                     |
| `longhorn_chart`      | check `files/values.yaml`                     |
| `metallb`             | check `files/values.yaml`                     |
| `ntfy`                | set to prefer small/medium (new — see `ntfy-deploy.md`) |
| `ntfy_bridge`         | set to prefer small/medium (new — see `ntfy-bridge-deploy.md`) |

## For each role

Replace `node_type`-based affinity with `node_size`-based equivalents. General guidance:
- Most monitoring/infra workloads: prefer `small` or `medium`, avoid `x-large` (reserve for compute-heavy)
- Storage-adjacent workloads: check whether they need to co-locate with specific node types

## Cleanup

Once all roles are updated and deployed, remove the old `node_type` labels from nodes.

## Dependencies

- `node-relabeling.md` must be complete first
