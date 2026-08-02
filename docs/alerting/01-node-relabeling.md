# Task: Relabel Cluster Nodes with Size-Based Labels — DONE

Replace the current ad-hoc `node_type` label values with a consistent size-based scheme so workload affinity rules are meaningful and portable.

## New label scheme

| Label value | Hardware         | Current `node_type` |
|-------------|-----------------|---------------------|
| `small`     | Potato nodes     | `potato`            |
| `medium`    | Pi with ≤4GB RAM | `pi` (subset)       |
| `large`     | Pi with ≥8GB RAM | `pi` (subset)       |
| `x-large`   | NUC              | `nuc`               |

Label key: `node_size` (new key, so existing `node_type` can be removed once all affinity rules are updated — coordinate with `workload-affinity-audit.md`).

## Implementation

1. Identify which nodes fall into each category (check `infra/inventory.yaml` and node specs)
2. Add `node_size` label to each node via Ansible (or `kubectl label node <name> node_size=<value>`)
3. Consider adding label application to the k3s setup role so new nodes get labelled automatically

## Note

Do not remove `node_type` labels until `workload-affinity-audit.md` is complete — existing workloads depend on it.

## Dependencies

None — can be done independently of the Ntfy work.
