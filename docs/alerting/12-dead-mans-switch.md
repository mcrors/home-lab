# Task: Dead Man's Switch for the Alerting Pipeline

Status: done, 2026-09-12. Built as the `dead_mans_switch` role, deployed to lib-pi-06.
The off-site half is deferred to `13-offsite-pipeline-watchdog.md`.

Send a recurring "all's well" message so that silence becomes the failure signal.

## What was built

A daily systemd timer on lib-pi-06, outside k3s, posting to the Alertmanager API so that
everything it sends travels the real pipeline to Signal.

| Alert | Purpose |
|---|---|
| `DeadMansSwitch` | The morning all-is-well message. Its absence is the signal. |
| `SignalCliImageStale` | Fires at 60 days so the upgrade prompt arrives while signal-cli still works. |
| `SignalCliTagUnreadable` | The tag stopped parsing as a build timestamp, so the staleness check is blind. |
| `SignalCliImageUnknown` | Prometheus has no `kube_pod_container_info` for signal-cli, so the check cannot run. |

### Why the staleness alert exists, and why it is proactive

The stated reason for wanting this at all was knowing when signal-cli needs a version swap,
which happens every few months. A daily heartbeat detects that badly: when signal-cli breaks,
the message stops arriving, so the detector for the thing you care about is silence.

Firing on image age instead inverts it. At 60 days signal-cli still works, so the alert travels
the normal path and lands on the phone as an ordinary notification. The README already records
that releases older than three months can stop working, so 60 days leaves roughly a month to act.

The `bbernhard/signal-cli-rest-api` `-ci` tags encode the image build time as a Unix epoch. This
was verified against Docker Hub `last_updated` across the tag history, matching to within a
minute in every case. The running tag is read from Prometheus via `kube_pod_container_info`, so
the check needs no cluster credentials on lib-pi-06.

Because that scheme is an upstream convention rather than a guarantee, an unparseable or
implausible tag raises its own alert. A staleness check that silently stops checking is worse
than no check at all.

### Why signal-cli is not auto-updated

Considered and rejected. The linked-device session lives in the `signal-cli-data` PVC, and a bad
upgrade means re-linking by QR code from the phone, which is manual and physical. The `-ci` tags
are per-commit CI builds, and `latest` lags them by months, so tracking the newest tag means
running bleeding-edge builds of the component carrying every alert. Worst of all the failure is
circular: an overnight auto-update that breaks signal-cli takes out the only channel that could
report it.

The bridge itself is not a constraint. Its entire coupling to signal-cli is one HTTP call to
`/v2/send` in `forward.sh`, so bumping `signal_cli_image_tag` never requires a bridge rebuild.

### Known gap

Signal is the only route to the phone, so a signal-cli failure cannot be reported in real time by
anything inside this design. `forward.sh` logs `result=error` and exits non-zero on a failed send,
so the failure is observable in-cluster, but every path to the phone runs through the broken
component. That is what ticket 13 exists to close.

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
