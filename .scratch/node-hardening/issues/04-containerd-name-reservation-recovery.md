Status: wontfix

# 04: Pods do not come back after a node reboot

## What happened

The nodes came back at 15:00 on 2026-08-27 and looked completely healthy — `Ready`, no
taints, no memory or disk pressure. But seven pods never restarted, and stayed dead for
six hours until deleted by hand.

What was actually broken: containerd assigns each container and each pod sandbox a
name, and refuses to reuse a name that is already taken. After the reboot it was still
holding names from before the reset, believing they belonged to containers that no
longer existed. Kubelet asked for those names, was refused, and retried forever:

```
failed to reserve container name "controller_metallb-controller-…_6":
  name … is reserved for "82f4bc002cbbf14c99907a11d8433110187d87b347c0a5df761424cb67c46175"
```

1,557 retries over six hours on lib-potato-04. On lib-pi-01, retry number **1623** —
that node had been broken since well before this incident and nobody had noticed.

It shows up two different ways, which matters for writing an alert that catches both:

- **container name taken** → pod shows `CreateContainerError` and keeps its IP address
- **sandbox name taken** → pod shows `Error`, has **no IP at all**, and never restarts

### What it cost

Not just the affected node. `cert-manager-webhook` was one of the dead pods, and
cert-manager routes every certificate operation through that webhook — so for six
hours no certificate anywhere in the cluster could be issued or renewed. Likewise
`metallb-controller`: while it was down, no new LoadBalancer service could get an IP.
Also dead: `alertmanager` (so no alert about any of this could have been delivered
anyway), `signal-bridge`, and `metallb-frr-k8s` on two nodes.

### Why nothing recovered on its own

Three separate mechanisms each declined to act, and each was behaving correctly:

1. The node stayed `Ready`, so nothing was ever evicted.
2. The pods' **phase** stayed `Running` — only the containers inside them were
   failing. ReplicaSet and StatefulSet controllers count phase, so as far as they were
   concerned the replicas existed and nothing was wrong.
3. Kubernetes never moves a running pod to another node. A pod stays on its node for
   life. The only thing that produces a replacement is deleting the pod object.

Nothing was watching for "pod is Running but its containers cannot start". That is the
gap, and it is why this ran for six hours with zero alerts.

### The fix that worked

`kubectl delete pod`. The taken name includes the pod's unique ID, so a recreated pod
gets a new ID, asks for a name nobody holds, and starts normally. All seven pods were
back within about a minute, and pods that were healthy on those nodes were untouched.

Restarting `k3s-node` also clears it, but restarts everything else on the node too.

## Scope

### 1. Find out if this is a known bug

Versions in play: containerd `2.1.5-k3s1.32`, k3s `v1.32.13+k3s1`. Search the
containerd and k3s issue trackers for `failed to reserve sandbox name` and
`is reserved for`. If a later release fixes it, upgrading may retire most of this
ticket, and that is worth knowing before building anything.

### 2. Work out whether a clean shutdown prevents it

The strong suspicion is that containerd got no chance to save its state, because the
watchdog cut the board dead mid-operation. If that is the cause, then fixing the hard
reset (ticket 05) stops this happening at all, and the rest of this ticket becomes a
safety net rather than the main fix.

This is directly testable: reboot one node with `systemctl reboot`, force-reset
another, and see which one comes back with all its pods. Ticket 05 carries the same
test — run it once, record the answer in both.

### 3. Make it visible

`PodNotReady` is already queued in `docs/alerting/alerts-to-create.md` and is the main
fix for the six-hour blind spot. Check the rule catches **both** presentations above —
the `Error` case has no pod IP, and expressions that assume a pod IP exists will miss
it entirely. `DeploymentReplicaMismatch` in the same doc is the second net and would
have caught all four dead services.

### 4. Decide whether to auto-fix it

We could run something that deletes any pod stuck in `CreateContainerError` or
`CreatePodSandboxError` for more than ~15 minutes. The fix is mechanical and we know it
works.

The risk is specific: anything with permission to delete pods will delete the wrong
ones if its filter is wrong, and cause exactly the kind of outage it was built to
prevent. A too-broad match during a normal rollout could delete pods that were starting
up perfectly happily.

So pick one deliberately:

- **Alert only.** `PodNotReady` fires, a human runs the runbook. Nothing can go wrong
  on its own.
- **Alert plus auto-delete.** Faster recovery, at the cost of a component that can
  cause an outage. If chosen, it matches only those two specific waiting reasons, has
  a dry-run mode, and has a hard cap on deletions per hour.

Write down which one and why. If auto-delete is chosen, the note should say what made
alert-only insufficient.

### 5. Write the runbook

Short entry in `docs/alerting/`: both symptoms, the `crictl ps -a` check that shows the
duplicate sandboxes, `kubectl delete pod` as the fix, restarting `k3s-node` as the
escalation.

Include one detail that will otherwise waste someone's time: the k3s service on these
nodes is called **`k3s-node.service`**, not `k3s-agent.service`. Running
`systemctl is-active k3s-agent` on a completely healthy node returns `inactive`.

## Acceptance criteria

- Written answer on whether a fixed containerd/k3s release exists.
- Written answer on whether a clean reboot avoids the problem, based on the actual
  test, not reasoning.
- `PodNotReady` confirmed to catch both the `CreateContainerError` and the no-IP
  `Error` case.
- A recorded decision on auto-deletion, with the reason.
- Runbook exists and names `k3s-node.service`.
- Reboot a node deliberately and every pod comes back with no manual intervention.

## Comments

### 2026-08-30 — clean reboot on lib-potato-04: all pods returned

Run as part of ticket 01's acceptance test. `systemctl reboot` on `lib-potato-04`;
every pod came back `Ready` on the same node with no manual intervention, no
`CreateContainerError`, no no-IP `Error`.

This is a meaningful subject: potato-04 is the node that logged 1,557 failed container
creations over six hours on 2026-08-27, so the same hardware and the same workload mix
recovered cleanly when the shutdown was orderly.

**What this establishes:** rebooting does not wedge containerd per se. The failure needs
something more than a restart, which is consistent with the hypothesis that the hard
reset is the cause.

**What it does not establish:** that the hard reset *is* the cause. This is one clean
reboot, and the wedge may be intermittent rather than deterministic. The other half of
the experiment — force-reset a node and see whether it comes back wedged — has not been
run. Until it has, ticket 05 is still unproven as the fix for this ticket.

Convenient overlap: ticket 06's acceptance test forces an unclean reset with
`echo b > /proc/sysrq-trigger` to check whether a log marker survives. That is exactly
the force-reset half of this experiment. Running 06 answers 06, 04 and 05 in one reboot.

Still open here: §1 (is there a fixed containerd/k3s release), §3 (does `PodNotReady`
catch both presentations), §4 (auto-delete decision), §5 (runbook).

### Correction, same day — it was two reboots, not one

The surviving logs show the deliberate `systemctl reboot` was followed ~106s later by a
**second, watchdog-initiated reboot** (see ticket 07). So the pods that came back `Ready`
did so after two consecutive reboots, the second one unplanned.

That strengthens rather than weakens the finding: two reboots in under four minutes, on
the node that wedged on 2026-08-27, and containerd came back clean both times.

It also changes what the second reboot tells us. The watchdog did not cut power — it
logged `shutting down the system because of error 101` and sent SIGTERM to PID 1, i.e. it
asked systemd to shut down. See the premise correction in ticket 05. A watchdog trip is
therefore not automatically the hard reset this ticket assumed, which means the causal
story "hard reset → containerd never saved state → name reservations stranded" is no
longer the only candidate and has not been demonstrated.

### 2026-09-01 — closed as wontfix

Operator decision: seen rarely, and there is a known one-command recovery. Not worth
building automation or a detection path for a fault that has occurred once. Reopen if it
happens again.

Ticket 05, which held the candidate preventive fix, was closed the same day. Its reasoning
matters here: a normal systemd shutdown already stops `k3s-node`, so the leading hypothesis
is that the shutdown overruns the watchdog daemon's 60s hardware window and the board is
cut partway through. Unverified, and confirming it needs a production node's network pulled
to time a shutdown.

**Recovery procedure, kept here so it is findable if this recurs:**

- **Symptom.** Pods stay in phase `Running` on a `Ready` node but never become ready, or
  sit in `Error`. No controller replaces them because the node looks healthy. In the
  2026-08-27 incident this ran 1,557 kubelet retry attempts over six hours on
  lib-potato-04 and hit attempt 1623 on lib-pi-01.
- **Confirm.** `crictl ps -a` shows duplicate sandboxes holding stale container name
  reservations.
- **Fix.** `kubectl delete pod <name>`. The reserved name includes the pod's unique ID, so
  a recreated pod asks for a name nobody holds and starts normally. All seven pods returned
  within about a minute, and healthy pods on the same nodes were untouched.
- **Escalation.** Restarting `k3s-node` also clears it, at the cost of restarting
  everything else on the node.
- **Gotcha.** The k3s unit on these nodes is `k3s-node.service`, not `k3s-agent.service`.
  `systemctl is-active k3s-agent` returns `inactive` on a completely healthy node.

**Not affected by this closure.** The six-hour blind spot was an alerting gap, and the
alerting work is tracked separately in `docs/alerting/alerts-to-create.md`
(`PodNotReady`, `DeploymentReplicaMismatch`), which the spec lists as out of scope for this
project. Closing 04 does not drop it. `PodNotReady` remains the main fix for the blind
spot, and the rule needs to catch both presentations above, since the `Error` case has no
pod IP and any expression assuming one will miss it.
