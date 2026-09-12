Status: ready-for-agent
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
