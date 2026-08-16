# Task: Consolidate Node Labeling into node_labels Role (Tech Debt)

Move all remaining node labeling out of `k3s/worker/tasks/main.yaml` and into the dedicated `node_labels` role, so labeling logic lives in one place and runs on all cluster nodes (servers and workers).

## Current state

`infra/roles/k3s/worker/tasks/main.yaml` sets three labels that belong in `node_labels`:

| Label | Logic |
|-------|-------|
| `memory` | Rounded RAM (e.g. `4GB`) |
| `iscsi_initiator` | `true` when RAM > 3GB |
| `node_type` | From `node_type` group var (already duplicated into `node_labels`) |

These only run on `k3s_workers`, so server nodes (potato-01/02/03) have never received `memory` or `iscsi_initiator` labels.

## What to do

1. Move the `memory`, `iscsi_initiator`, and `node_type` label tasks from `k3s/worker/tasks/main.yaml` into `infra/roles/node_labels/tasks/main.yaml`
2. Move the `longhorn-storage` and `node.longhorn.io/create-default-disk` label tasks out of the inline block in `infra/playbooks/longhorn.yaml` and into `node_labels` as well (gated on a `longhorn_storage_node` group var or host var)
3. Remove the labeling block from the worker task and the longhorn playbook
4. Verify all nodes (servers + workers) get all labels after the change

## Note

`node_type` is already set by `node_labels` as of the work in `01-node-relabeling.md` — remove the duplicate from the worker task as part of this ticket.

The longhorn labels were previously only applied by running the full longhorn playbook, which also does disk setup. Moving them into `node_labels` means labeling can be re-run safely without risking disk operations.

## Dependencies

- `01-node-relabeling.md` complete (node_labels role already exists)
- `06-workload-affinity-audit.md` complete (safe to remove old labels once affinities are updated)
