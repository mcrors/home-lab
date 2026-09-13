Status: resolved
Blocked by: 04

# Audit and fix every service icon

## Context

Ticket 04 writes an icon name per service from the plan's checklist. Those names are guesses at what
the icon pack actually calls each thing, and several will not resolve. `prometheus` stands in for two
different services, and the four annotations already in the repo were written without ever being
rendered.

A missing icon degrades to a text placeholder rather than an error, so nothing fails loudly. This
ticket is the pass that looks at the page and fixes what is wrong.

## Scope

Open the live dashboard and check every card, including Alertmanager, kube-state-metrics, Ntfy and
Traefik, which were annotated before any dashboard existed to render them.

For each broken or wrong icon, resolve the correct name. Homepage's default `icon:` value is a name
from the Dashboard Icons pack; the pack's index is the authority on spelling, not the service's own
branding. Where a service has no icon in the pack, choose between:

- a Material Design icon, `mdi-<name>`, which Homepage supports directly
- a self-hosted file under the ConfigMap, if the card is worth the extra weight

Prefer `mdi-` over adding a file. Record the choice in the annotation and move on.

Update the icon names in place in each owning role, then re-run that role's playbook tag so the
annotation reaches the cluster.

Where the icon name in the annotation differs from the one written in
`docs/homepage/homepage-project-plan.md` row HOM-04, correct the plan too, so the checklist matches
what is deployed.

## Acceptance criteria

- Every card on the dashboard renders a real icon. No text placeholders, no broken images.
- `kube-state-metrics` and Blackbox Exporter are visually distinguishable; they should not share one generic Prometheus icon.
- Every icon name that changed is corrected in both the role and the plan doc.
- Any `mdi-` substitution or self-hosted file is listed under `## Comments` with the reason.

## Comments

Closed 2026-09-13. Every card renders a real icon and no two cards share one.

Rory checked the live page and confirmed all icons resolve, so the pack's spellings that ticket 04
guessed turned out to be right in every case. No name needed correcting for resolution. The four
pre-existing annotations (Alertmanager, kube-state-metrics, Ntfy, Traefik), which had never been
rendered when they were written, resolve too.

The second criterion was not met on first look, and is the only thing this ticket actually changed.
Three of the fifteen cards rendered the identical Prometheus icon: Blackbox Exporter,
kube-state-metrics, and the off-cluster Prometheus. Two of those sit next to each other in `Infra`.
Nothing appeared broken, which is exactly why it needed a deliberate look rather than a glance.

### mdi substitutions

Both taken per this ticket's preference for `mdi-` over a self-hosted file. `prometheus` is now used
only by the service that actually is Prometheus.

| Card | Was | Now | Reason |
|---|---|---|---|
| kube-state-metrics | `prometheus` | `mdi-kubernetes` | It reports Kubernetes object state; the Dashboard Icons pack has no kube-state-metrics mark |
| Blackbox Exporter | `prometheus` | `mdi-radar` | It probes endpoints from outside; the pack has no blackbox-exporter mark |

Both names were verified to exist at the CDN base homepage actually uses,
`https://cdn.jsdelivr.net/npm/@mdi/svg@latest/svg/`, read out of the running v2.3.0 image rather than
taken from the docs. Homepage resolves an `mdi-` prefix against that base and an `si-` prefix against
simple-icons.

Both roles were re-run (`--tags ksm,blackbox`) and the icon names in
`docs/homepage/homepage-project-plan.md` row HOM-04 were corrected to match what is deployed, as this
ticket requires.

### Known trade-off, accepted

Material Design icons are monochrome silhouettes where the Dashboard Icons pack gives full-colour
logos, so those two cards read as a different style from their neighbours. Rory looked and accepted
it for now. The alternative is self-hosting a file per card, which costs ConfigMap weight for a
cosmetic gain. Worth revisiting only if the mismatch becomes annoying in daily use.

### Ticket 04

This closes the one acceptance criterion ticket 04 deferred here rather than met: "All icons resolve;
no broken image placeholders." It is now satisfied.

Resolved.
