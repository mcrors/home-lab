Status: needs-triage
Blocked by: 06

Not a decision yet. Look at the finished dashboard first, then decide whether any of this is worth
doing. The cost is written up below so that decision has something to weigh.

# Per-service live-data widgets

## Context

Homepage can pull live stats into a service card through a per-service API widget: Sonarr queue
depth, Transmission active torrents, and so on. This is cosmetic and comes last, once the dashboard
is stable.

See `docs/homepage/homepage-project-plan.md` row HOM-05.

## Scope

Add widgets for the services that support them:

- Sonarr: queue and missing episodes
- Radarr: queue and missing films
- Prowlarr: indexer count
- Transmission: active torrents

Each widget needs an API key. Do not put one in a `gethomepage.dev/widget.*` annotation: annotations
are readable by anything that can list Ingresses. Put the key in a Secret, project it into the pod as
an environment variable, and reference it from `services.yaml` with Homepage's `{{HOMEPAGE_VAR_*}}`
substitution. That means this ticket also touches the chart from ticket 01 and the role from
ticket 03, and it makes the widget-carrying services static `services.yaml` entries rather than
discovered ones. Decide per service whether a live number is worth that, and record the reasoning
under `## Comments`.

Stop at the first two working widgets if the pattern proves more trouble than the numbers are worth.

## Acceptance criteria

- At least one *arr widget shows live data on the dashboard.
- No API key appears in any annotation, in `git log`, or in `kubectl get ingress -o yaml`.
- Homepage logs show no widget errors.
- The per-service decision is recorded under `## Comments`.
