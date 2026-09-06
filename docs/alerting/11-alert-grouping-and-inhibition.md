# Task: Group and Inhibit Related Alerts

Stop one underlying fault producing several separate notifications.

## Current state

The deployed Alertmanager route (verified from `configmap/alertmanager` in the `alertmanager`
namespace) has **no `group_by`**. With `group_by` unset, Alertmanager places every alert matching
the route into a single aggregation group, so unrelated alerts are batched into one notification
per `group_interval` (5m).

Inhibit rules are deployed and working for the critical-suppresses-warning case on
`alertname` + `instance`.

## Two mechanisms, two different jobs

| Mechanism | Use for |
|---|---|
| `group_by` | Many instances of the *same* alert collapsing into one message |
| `inhibit_rules` | A *symptom* alert suppressed while its *cause* alert is firing |

"If both fire, it's the same thing" is the inhibit case.

## Proposed grouping

```yaml
route:
  group_by: [alertname, namespace]
```

Verify this does not over-collapse node-level alerts, which carry `instance` rather than `namespace`.

## Proposed inhibition: replica mismatch suppresses probe failure

When a Deployment is at 0 replicas, the ingress in front of it also fails its probe. The replica
mismatch is the actionable alert; the probe failure is noise.

```yaml
- source_matchers:
    - alertname="DeploymentReplicaMismatch"
  target_matchers:
    - alertname="BlackboxProbeFailed"
  equal: [namespace]
```

## Blocker

This rule **cannot be written today**. Inhibition joins source and target on the labels named in
`equal:`. Blackbox alerts carry `instance` (a URL); kube-state-metrics alerts carry `namespace` and
`deployment`. There is no shared label.

Ingress service discovery attaches `namespace` to probe targets, which supplies the join key.

## Dependencies

- `10-blackbox-ingress-autodiscovery.md` must land first for the inhibit rule.
- The `group_by` change is independent and can go in on its own.
