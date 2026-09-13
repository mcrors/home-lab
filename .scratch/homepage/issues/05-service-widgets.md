Status: ready-for-agent
Blocked by: 06

Being worked one service at a time: decide, deploy and record each before looking at the next. The
cost estimate written below turned out to be too high; see `## Comments` for why and for the running
per-service decision table.

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
- longhorn: maybe
- plex: maybe
- pihole: maybe
- omv: maybe
- calender: maybe
- stocks: maybe
- traefik: maybe
- uptimte-kuma: maybe

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

## Comments

Working through the service list one at a time, deciding and deploying each before looking at the
next. Each widget gets its own entry below.

### The ticket's cost model was wrong

This ticket assumed a widget forces its service to become a hardcoded `services.yaml` entry, because
the API key cannot go in an annotation. The first half is wrong, so every widget below costs less than
this ticket priced it.

Homepage does apply `{{HOMEPAGE_VAR_*}}` substitution to services discovered from Ingress
annotations. It builds the service object from the annotations and then round-trips it:

```js
Object.keys(a.metadata.annotations).forEach(c => {
  c.startsWith(g.T6) && h.h(b, c.replace(`${g.kD}/`, ""), a.metadata.annotations[c])
});
try { b = JSON.parse((0, f.Qj)(JSON.stringify(b))) }
catch (a) { o.error("Error attempting k8s environment variable substitution.") }
```

`g.T6` is the `gethomepage.dev/widget.` prefix and `f.Qj` is `substituteEnvironmentVars`, the same
function applied to `settings.yaml`. Read out of the running v2.3.0 image
(`/app/.next/server/pages/index.js`, module 52207) rather than taken from the docs, the same way
ticket 06 checked the icon CDN base.

So the annotation holds the literal text `{{HOMEPAGE_VAR_SONARR_KEY}}`, the real key lives only in the
pod environment, and the service stays discovered. Nothing mangles the braces on the way in: Ansible
does not Jinja-render a `values_files` entry and Helm does not template values files.

The chart needed no change. `extraEnv` already existed in `values.yaml` and was already rendered by
`deployment.yaml`, scaffolded by ticket 01 for exactly this. So the per-widget cost is one vault key,
one key in a shared Secret, one `extraEnv` entry, and two annotations in the owning role. The one-off
cost was the Secret task and the `homepage_widget_secret_name` default.

Two traps worth recording. The name after `HOMEPAGE_VAR_` must match the placeholder exactly, because
substitution matches the prefix and treats the rest as a literal; a mismatch leaves the raw `{{...}}`
in the widget config and the service answers 401. And because substitution happens inside a JSON
string, a key containing a quote or backslash would break the parse, and the `catch` above only logs.
API keys of the *arr family are 32 hex characters, so this cannot bite there.

### Decisions

| Service | Decision | Reasoning |
|---|---|---|
| Sonarr | Done | Queue depth and missing-episode count are the two numbers worth a glance before opening the app. Cheap once the Secret plumbing existed. |
| Radarr | Done | Same widget type as Sonarr with a different name and port. Nothing new to invent, so the only question was whether the numbers are wanted, and they are. |
| Prowlarr | Done | Taken against a recommendation to skip. The widget shows lifetime totals rather than the indexer count the ticket assumed, but the cost is now trivial and Rory wants the numbers on the page. |
| Transmission | Done | Four current-state numbers, and the cheapest widget of the four: its RPC needs no credentials, so there is no vault key and no Secret change. |
| Longhorn | Rejected | Built, deployed, looked at, removed. It worked; it just looked wrong on the page. |

The remaining services in the scope list are undecided and are being taken one at a time.

### Sonarr

Deployed 2026-09-13. The card shows live data; Rory confirmed on the page.

`url` is the in-cluster Service, `http://sonarr.sonarr.svc.cluster.local:8989`, not
`https://sonarr.houli.eu`. Homepage fetches widget data server-side from its own pod, so the public
host would leave the cluster, cross Traefik and depend on the pod trusting our cert chain, only to
arrive back at the same Service. Confirmed reachable before writing anything: a request from the
homepage pod to that address returned 401, which proved DNS, routing, and that auth is required.

The key was already generated by Sonarr in `/config/config.xml`; nothing had to be rotated. Rory added
it to `services/group_vars/all/vault.yaml` as `vault_sonarr_api_key`. It was confirmed to match the
live key by comparing SHA-256 hashes, so a typo could not cause a silent 401.

One Secret, `homepage-widgets`, holds a key per service rather than one Secret per service, so widgets
two onward cost a key instead of a resource. It uses `stringData` and the task sets `no_log: true`,
following `infra/roles/signal_bridge`. `extraEnv` is passed through the helm task's `values:` rather
than `files/values.yaml`, because it must reference `homepage_widget_secret_name` and a `values_files`
entry is never Jinja-rendered; this matches how the plex role passes `plex_claim_secret_name`.

Acceptance criteria, verified against the cluster rather than the repo:

- An *arr widget shows live data. Yes, Sonarr.
- No key in any annotation, in `git log`, or in `kubectl get ingress -o yaml`. Verified by grepping the
  live key value against all Ingresses, all ConfigMaps, the repo, and `git log -p --all`: zero hits in
  each. The Ingress carries only `{{HOMEPAGE_VAR_SONARR_KEY}}`.
- No widget errors in the homepage logs. None, and specifically no
  `Error attempting k8s environment variable substitution`.
- Per-service decision recorded. Above.

### Radarr

Deployed 2026-09-13, same day as Sonarr. The card shows live data; Rory confirmed on the page.

Identical in shape to Sonarr: `widget.type: radarr`, the in-cluster Service at
`http://radarr.radarr.svc.cluster.local:7878`, and the key as placeholder text. Reachability was
confirmed the same way before writing anything, a 401 from the homepage pod. The key already existed in
`/config/config.xml` and Rory added it to the vault as `vault_radarr_api_key`, hash-matched against the
live key before deploying.

This is the first widget to exercise the shared-Secret design, and it cost what the Sonarr entry
predicted: one `stringData` key, one `extraEnv` entry, three annotations. No new resource, no chart
change. The annotation comment in the radarr role points at the sonarr role rather than repeating the
reasoning, so there is one copy of the explanation.

The leak check was re-run for both keys together after this deploy, against all Ingresses, all
ConfigMaps, the repo and `git log -p --all`: zero hits for either. Logs clean.

Worth noting for anyone reading this later: an ad-hoc `ansible localhost -m debug` run does not load
`services/group_vars` unless it runs from `services/`. Run from the repo root it reports a vault
variable as undefined even when it is correctly defined, which briefly looked like a missing key here.

### Prowlarr

Deployed 2026-09-13 and confirmed on the page.

The scope list above says "Prowlarr: indexer count". That is wrong, and the widget cannot do it. Chunk
`1081` of the running image fetches the `indexerstats` endpoint and sums four counters across every
indexer: `numberOfGrabs`, `numberOfQueries`, `numberOfFailGrabs`, `numberOfFailQueries`. There is no
indexer count among them.

I recommended skipping it on that basis. These are cumulative lifetime totals rather than current
state, so unlike a Sonarr queue depth they do not tell you anything you would act on: a query total
that only ever rises is wallpaper after the first week, and the one genuinely useful signal, a climbing
failure count, is easier to see as a rate in Prometheus than as a raw total on a card.

Rory chose to take it anyway, which is the right call to be his: the cost argument had already
evaporated by this point, so the only question left was whether he wants the numbers in front of him
daily, and he does. Recorded here so the reasoning is legible if the card is later removed.

Same shape as the other two, at `http://prowlarr.prowlarr.svc.cluster.local:9696`, key hash-matched
before deploying. Leak check re-run across all three keys after the deploy: zero hits each.

### Transmission

Deployed 2026-09-13 and confirmed on the page. Shows leeching count, download rate, seeding count and
upload rate, all current state rather than lifetime totals.

Annotations only. This widget needs no key, no username and no password, which is not how the ticket
priced it and not how the other three work. Transmission's RPC has authentication disabled:

```
"rpc-authentication-required": false,
"rpc-username": "",
"rpc-whitelist-enabled": false,
"rpc-host-whitelist-enabled": false,
"rpc-bind-address": "0.0.0.0",
```

The `127.0.0.1,::1` value of `rpc-whitelist` is not enforced, because `rpc-whitelist-enabled` is false.
Settings live at `/config/transmission-home/settings.json`, not `/config/settings.json`.

One thing to know before reading a 409 as a failure: a POST to `/transmission/rpc` answers
`409` with an `X-Transmission-Session-Id` header. That is Transmission's CSRF handshake and homepage
retries with the header. It is not an auth challenge.

**This surfaced a security problem, filed separately.** Because RPC auth is off and no NetworkPolicy
exists in that namespace, any pod in the cluster can drive Transmission's RPC unauthenticated, which
includes adding a torrent and setting `download-dir` to any path the container can write, so it reaches
the NFS media and downloads mounts. The widget neither caused nor worsened this; needing no credentials
is how it was noticed. Tracked in `.scratch/cluster-access-control/issues/01-transmission-rpc-unauthenticated.md`
rather than here, because a fix is an access-control decision rather than a dashboard change.

### Longhorn

Tried and removed on 2026-09-13. Not a failure to make it work: it worked, and Rory judged that it
looked wrong in the header. Reverted and redeployed, leaving zero Longhorn references in the live
ConfigMap. Longhorn still has its service card in `Infra` from `longhorn-ingress`; only the header
widget is gone.

Two things learned that are worth keeping, because they will apply to any other information widget.

**Longhorn is an information widget, not a service card.** It has no directory under
`/app/src/widgets` (159 service widgets) and instead lives in `/app/src/components/widgets`, alongside
`datetime`, `glances`, `greeting`, `kubernetes`, `logo`, `openmeteo`, `openweathermap`, `resources`,
`stocks`, `unifi_console` and `weather`. Those are configured in `widgets.yaml` and attach to no
Ingress, so the annotation pattern used for the four *arr-style widgets does not apply to them.

**The URL goes in `settings.yaml`, not `widgets.yaml`.** This cost a debugging round trip. The card
rendered "API Error"; `/api/widgets/longhorn` answered
`400 {"error":"Missing Longhorn URL"}`. The route reads
`getSettings()?.providers?.longhorn`, so the URL belongs in a top-level `providers:` block in
`settings.yaml`, and a `url:` key on the `widgets.yaml` entry is read by nothing. Once moved, the route
returned 200 with real per-node capacity. Expect the same split for `stocks` if that is ever taken.

The in-cluster Service was the right choice regardless: `/api/widgets/longhorn` is a server-side route,
so the fetch leaves the homepage pod, and `longhorn-frontend.longhorn-system.svc.cluster.local` answered
`/v1/nodes` with 200 and no auth. That last detail is part of why
`.scratch/cluster-access-control/` now exists.
