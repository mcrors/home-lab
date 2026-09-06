# Task: Add Node Reboot Frequency Panel to Grafana

Status: not started.

**Blocked by a bug, not by effort.** `NodeRecentlyRebooted` in `alerts.yaml` selects
`up{job=~"node-exporter|node"}` while the job is actually named `node_exporter`. Prometheus anchors
regex matchers fully, so that rule matches nothing and has never fired. The panel below queries the
raw `node_boot_time_seconds` metric and would work, but the whole reboot-visibility story
(this panel, `NodeUnexpectedReboot`, `MultiNodeRebootWindow`) is worth doing in one pass after the
job name is fixed.

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
changes(node_boot_time_seconds{job="node-exporter"}[30d])
```

Show as a stat panel with one series per node, time range selectable. A value of 0 means no reboots in the window; anything higher warrants a check of the journal on that node.

## Note

This counts all reboots regardless of cause — watchdog, manual, power loss. To confirm a specific reboot was watchdog-triggered, check the journal on the node after the fact (`journalctl -b -1` to see the previous boot's last entries).

The `node_boot_time_seconds` metric is already being scraped — no new exporters or recording rules needed.
