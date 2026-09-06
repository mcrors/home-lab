# Task: Dead Man's Switch for the Alerting Pipeline

Send a recurring "all's well" message so that silence becomes the failure signal.

## Semantics

Every alert in this system is a positive signal: something fired, a message arrived. That design
cannot report its own death. If Prometheus, Alertmanager, ntfy-bridge, ntfy or signal-bridge stops,
no alert is generated and the phone stays quiet — indistinguishable from a healthy cluster.

A dead man's switch inverts this. A message arrives on a schedule while the pipeline is healthy.
Its absence means the pipeline is broken.

This was anticipated in `.scratch/signal-bridge/spec.md`: "No heartbeat. Out-of-band ntfy morning
message acts as the canary instead." It has not been implemented.

## The generator must sit outside the pipeline it tests

`ntfy` and `signal-bridge` both run in-cluster. A canary generated inside k3s and delivered through
that same path cannot distinguish "cluster down" from "pipeline down". Both mean "go look", so this
is acceptable, but the generator itself must not be a k3s workload or it dies with the thing it is
watching.

Candidate hosts outside k3s:

- `lib-hp-01.home` (already scraped by node_exporter, not a cluster member)
- the docker-server
- lib-pi-06 (already hosts Prometheus outside the cluster)

## Weakness: absence detection is a human job

A morning message that fails to arrive relies on someone noticing nothing happened. That is the
signal people are worst at, especially on a normal busy morning.

Options, roughly in increasing order of reliability:

1. **Scheduled ntfy message only.** Cheapest. Depends entirely on the human noticing silence.
2. **External dead man's switch** (healthchecks.io, Dead Man's Snitch). A cron pings the service on
   a schedule; the service alerts *you* when the ping stops. Survives total cluster loss, because
   the alerting lives off-site. Costs an outbound third-party dependency.
3. **Prometheus `Watchdog` alert.** An always-firing rule routed to a receiver that expects it. The
   standard pattern, but it validates Prometheus → Alertmanager → receiver, and dies with
   Prometheus rather than reporting on it.

## The trade-off to decide

Option 2 is the only variant that still reaches the phone when the whole cluster is down, which is
the scenario the switch exists for. It costs an outbound dependency on a third party, which cuts
against the reason ntfy was self-hosted in the first place. Option 1 keeps everything in-house and
accepts that a human has to notice silence.

## Open questions

- Which host runs the cron?
- Acceptable to depend on a third-party endpoint for this, given ntfy already relays through
  ntfy.sh for iOS push?
- Cadence: daily morning message, or a shorter interval with a longer grace period?
