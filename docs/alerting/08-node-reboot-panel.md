# Task: Add Node Reboot Frequency Panel to Grafana

Status: unblocked, panel still to build.

The bug that blocked this is fixed. `NodeRecentlyRebooted` selected `up{job=~"node-exporter|node"}`
while the job is named `node_exporter`, and Prometheus anchors regex matchers fully, so the rule
matched nothing and never fired. On 2026-09-12 it was fixed and renamed `NodeRebooted`, and
`MultiNodeRebootWindow` was added alongside it. Both are deployed on lib-pi-06 and evaluating.

The alerts now carry the reboot-visibility story on their own. This panel adds history, showing
reboot frequency per node over a long window, which the alerts cannot.

Note there is no dashboard provisioning in this repo. `infra/roles/grafana/files/values.yaml` has
`dashboardProviders` and `dashboards` entirely commented out, so any dashboard added today lives
only in Grafana's database and is not reproducible from code. Decide whether to turn provisioning
on before hand-building panels.

Add a panel to track how often each node reboots over time, using the `node_boot_time_seconds` metric already scraped by node_exporter.

## Background

Hardware watchdog was deployed to all Pi nodes and lib-potato-04 to trigger an automatic reboot if the node loses gateway connectivity. We want visibility into how frequently this (or any other cause) is triggering reboots without needing a noisy alert for each event.

## What to do

Add a panel to the existing node health dashboard with the following PromQL:

```promql
changes(node_boot_time_seconds{job="node_exporter"}[30d])
```

The job name here is `node_exporter` with an underscore. The earlier version of this doc said
`node-exporter`, which is the same mistake that kept the alert from firing and would have returned
an empty panel.

Show as a stat panel with one series per node, time range selectable. A value of 0 means no reboots in the window; anything higher warrants a check of the journal on that node.

## Note

This counts all reboots regardless of cause — watchdog, manual, power loss. To confirm a specific reboot was watchdog-triggered, check the journal on the node after the fact (`journalctl -b -1` to see the previous boot's last entries).

The `node_boot_time_seconds` metric is already being scraped — no new exporters or recording rules needed.
