# Task: Add kube-state-metrics Dashboard to Grafana

Import a cluster-level Grafana dashboard to visualise deployment health, pod states, node conditions, and resource requests vs limits using the kube-state-metrics data already being scraped.

## Background

kube-state-metrics is deployed and Prometheus is scraping it, but there is no dashboard surfacing that data yet. Several existing alerts (KubeNodeNotReady, PodCrashLooping, DeploymentReplicaMismatch) fire from these metrics — the dashboard gives the at-a-glance view to accompany them.

## What to do

1. Import Grafana community dashboard **ID 13332** (kube-state-metrics v2) as a starting point
2. Set the Prometheus datasource to match the existing datasource name in the Grafana setup
3. Verify the following panels render correctly against the cluster:
   - Deployment replica desired vs available
   - Pod phase breakdown (Running / Pending / Failed)
   - Node Ready condition per node
   - Container resource requests vs limits
4. Remove or hide any panels that reference metrics not present in this setup (e.g. HPA, PodDisruptionBudget if not in use)

## Note

If dashboard 13332 doesn't align well with the k3s metric labels, dashboard **15172** (Kubernetes cluster overview) is an alternative starting point.
