Status: resolved
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
| Plex | Done | Current stream count is the number worth having. The three library counts come along with it and barely move. |
| Pi-hole | Out of scope | Not in the cluster. The spec already assigns its annotation to whichever project brings it in. Struck from this list rather than left looking undone. |
| OpenMediaVault | Skipped | Rory's call, 2026-09-13. |
| Calendar | Done | Upcoming Sonarr and Radarr releases, monthly grid. Needs no credentials of its own. Prompted the 3-column Media layout below. |
| Stocks | Deferred | Needs an external market-data provider rather than anything in the cluster, so it has nothing to do with the rest of this ticket. |
| Traefik | Deferred | Rory's call. The card already exists and links to the dashboard. |
| Uptime Kuma | Deferred | Rory's call. The card already exists in CI/Ops. |

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

### Plex

Deployed 2026-09-13 and confirmed on the page. Shows current streams, then album, movie and TV counts.
Streams is the current-state number that justifies the card; the library counts are near-static.

Same annotation pattern as the *arr widgets, at `http://plex.plex.svc.cluster.local:32400`. The widget's
API template is `{url}{endpoint}?X-Plex-Token={key}`, so the key travels as a query parameter rather
than a header, which changes nothing about how it is stored.

**The credential is broader than the others.** It is Plex's `PlexOnlineToken`, read from
`/config/Library/Application Support/Plex Media Server/Preferences.xml`, and it authenticates the Plex
account rather than only this server. Stored the same way as the *arr keys and verified absent from
every Ingress, ConfigMap, repo file and git history, but worth knowing it is closer to an account
password than to a server-scoped API key.

Held as `vault_plex_api_key`. That name is deliberately close to the other three and deliberately
distinct from the pre-existing `vault_plex_claim_token`, which the plex role uses for first-time server
claiming and which is unrelated.

Also worth recording for later widgets: `/app/src/widgets/<name>/component.jsx` is readable JSX in the
running image. Reading that is much cheaper than decompiling the minified chunks in
`/app/.next/server`, which is how the earlier widgets in this ticket were checked.

### OpenMediaVault

Skipped on 2026-09-13 at Rory's call, before the design was worked out. What had been established, in
case it is revisited:

The widget takes a mandatory `method`, and `component.jsx` returns `null` for anything else, so one
card shows exactly one of three things: `services.getStatus` (OMV service up/down counts),
`smart.getListBg` (SMART disk health) or `downloader.getDownloadList`.

Two things would have made it the most awkward widget in the list. OMV is off-cluster, so it is a
static `services.yaml` entry rather than a discovered Ingress, and the widget would have to attach to
the existing NAS entry there. And `services.yaml` already records that `omv.houli.eu` serves plain
HTTP and refuses 443, while OMV's RPC authenticates with a username and password rather than an API
token, so credentials would have crossed the LAN unencrypted on every widget poll.

### Calendar

Deployed 2026-09-13 and confirmed on the page, in the monthly grid view. Agenda was deployed first on
my recommendation; Rory looked at both and preferred the grid.

It needs no credentials. Each integration names an existing card by group and name, and homepage reuses
that card's configured url and key, so the Sonarr and Radarr tokens are not repeated. `service_group`
must be the leaf group the card sits in, `Arr`, not the parent `Media`; a mismatch is silent and
presents as a calendar that renders but stays empty.

**The nesting cost a round trip and is worth knowing.** The Calendar has no Ingress, so it is a static
`services.yaml` entry, the first service card in that file. Declaring its group at the top level of
`services.yaml` and relying on the `settings.yaml` layout to nest it under Media is not enough: it
rendered as its own section below every other one. Homepage resolves a group name with a recursive
search that tests each top-level entry's own name before descending, and records a parent only when it
descends, so a top-level `Calendar` is found immediately with no parent. `Streaming` and `Arr` avoid
this only because nothing declares them in `services.yaml`; they exist solely in the merged layout tree,
where they are found as children of Media. A card written in `services.yaml` must therefore be nested
under its parent group there as well. In that file an array value is a group and a map value is a
service, which is how the parser tells them apart.

### The Media section is now three columns

Not a widget, but it came out of this ticket and it changed five roles, so it is recorded here rather
than lost. Rory's call after seeing the Calendar sitting awkwardly in a flat four-column Media row.

`Media` now holds no cards of its own, only three subgroups rendered as a 3-column grid: `Calendar`,
`Streaming` (Plex, Transmission) and `Arr` (Prowlarr, Radarr, Sonarr). Subgroup headings are suppressed
with `header: false`, so the page shows one "Media" rule above three bare columns.

The nesting is declared only in the `settings.yaml` layout, where any nested object value becomes a
subgroup and string or number values like `style` and `columns` are skipped. Services still carry a
flat `gethomepage.dev/group` naming a leaf, so moving a card between columns is a one-word annotation
change. Any `style` other than `row` renders a vertical stack. Cards sort by weight then name, and
nothing sets a weight, so order is alphabetical.

This supersedes the `Media: {style: row, columns: 4}` entry that ticket 02 wrote.

### Comment pass

Rory asked for a clean-code pass over the inline YAML comments before committing. Across the eight
files this ticket touched, 123 comment lines went to 78: sonarr 14 to 4, plex 15 to 5, transmission 12
to 3, the homepage role tasks 39 to 24, and radarr and prowlarr to zero, since `{{HOMEPAGE_VAR_*}}`
explains itself once the pattern is written out in one place. The two homepage config files grew a
little because they gained the Calendar and the 3-column layout.

What was kept is what misleads someone editing that line: the placeholder is not a secret and its name
must match, the Plex token is account-scoped, Transmission's 409 is a CSRF handshake, the Calendar must
be nested in `services.yaml` too, and card order is alphabetical unless weighted. The reasoning behind
each decision stays here.

### The Infra section is three columns too

Same pattern as Media, applied after Rory saw the Media split and wanted the rest of the page to match.
`Infra` now holds no cards directly, only `Metrics` (Blackbox Exporter, kube-state-metrics), `Alerting`
(Alertmanager, Ntfy) and `Platform` (Longhorn, Traefik), an even 2/2/2. `CI/Ops` and `Off-Cluster` stayed
flat and moved from `columns: 4` to `columns: 2`, because at 4 their two cards each filled half a row and
left the rest blank.

**Two infra roles gained a task-level tag, and that is the part worth keeping.** Traefik's annotations
live in `k3s_config`, which shares a play with `metallb` and `cert_manager` and also updates CoreDNS and
the Traefik HelmChartConfig. Longhorn's live in `longhorn_chart`, whose play includes the Longhorn helm
upgrade. Neither had task-level tags, so the smallest runnable unit for a one-word annotation change was
the cluster's networking, certs and storage layer. Adding `tags: traefik-ingressroute` and
`tags: longhorn-ingress` makes those two objects applyable on their own; `--list-tasks` confirmed the
pair selects exactly two tasks before anything was run.

The other four still have no task-level tags, so `--tags blackbox,ksm,alertmanager,ntfy` re-ran 19 tasks
to change four annotations. It came out clean: 4 changed, and the only pod that restarted anywhere was
homepage. Alertmanager was not interrupted, which was the risk flagged beforehand. Worth adding the same
narrow tags there if these annotations are touched again.

## Closing note

Closed 2026-09-13. Six widgets live (Sonarr, Radarr, Prowlarr, Transmission, Plex, Calendar), one tried
and rejected (Longhorn), one out of scope (Pi-hole, not in the cluster), and four deliberately deferred
(OpenMediaVault, stocks, Traefik, Uptime Kuma). Every acceptance criterion is met, and each per-service
decision is recorded above as this ticket required.

The ticket's own cost model was the main thing it got wrong, and that is fixed in the record rather than
worked around: widgets do not force a service out of Ingress discovery, and the chart never needed a
change because ticket 01 had already scaffolded `extraEnv`.

Reopen when a new service arrives that is worth a widget. The per-widget recipe is three annotations in
the owning role, one key in the `homepage-widgets` Secret, and one `extraEnv` entry, with the URL always
the in-cluster Service. Two traps to re-read first: the name after `HOMEPAGE_VAR_` must match the
placeholder exactly, and a card written in `services.yaml` must be nested under its parent group there,
not only in the `settings.yaml` layout.
