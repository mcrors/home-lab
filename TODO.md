# Media Setup
* Install and configer homarr
* Install and configer JellyFin
    * Once this is working, it will require side loading the client to the TV
* Move prowlarr, sonarr and radarr to a single helm chart with 3 different value files

# Security
* move plex to metallb and https (maybe)
* Is there a way to add TLS to the exporters to prometheus
* Update helm chart ClusterRoles to Roles

# Monitoring
* Add cron exporter to all hosts
* Add lvm exporter to iscsi target
* Add Blackbox exporter
* Create Temperature monitoring and fan management app
* Setup up Loki for log storage
* Create grafana dashboards for:
    * host health -> green or red depending on if the host is reachable
    * Cron jobs -> List of cron jobs with last 10 run results
* Set up alerting for specific metrics
* add cAdvisor:
    * exporter
    * dashboard
* Add alloy
* Setup alerts for disk space
* Set up notifications

* Check that the volumes are mounted on fstab

# Backup volumes on iscsi Target
* Clean up log file
    * Log to the same file for a week, then truncate the file
    * maybe do this in a cron job

# Self hosted container registry
* Determine which registry to use
* Set up automated vendoring of specific images
    * This should include periodic checks for updates

# Updates
* automated security updates
* debian bookworm update
* k3s update


# Clean up ansible playbooks

# Other Services
* Look into paperless service
* Add smpt server
* Add alert manager
