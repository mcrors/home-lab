# Media Setup
* Install and configer homarr
* Explore setting up Plex with ramdisk for transcoding
* Move prowlarr, sonarr and radarr to a single helm chart with 3 different value files

# Security
* move plex to metallb and https (maybe)
* Add authentik
* Update helm chart ClusterRoles to Roles
* Is there a way to add TLS to the exporters to prometheus

# Monitoring
* Update blackbox exporter for endpoints that require auth
* Setup up Loki for log storage
* Create grafana dashboards for:
    * Cron jobs -> List of cron jobs with last 10 run results
* Set up alerting for specific metrics
* add cAdvisor:
    * exporter
    * dashboard
* Add alloy
* Setup alerts for disk space
* Set up notifications
* Create Temperature monitoring and fan management app
* Check that the volumes are mounted on fstab
* Add the following exporters and dashboards:
    * cron
    * lvm
    * pi-hole
    * postgres

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
* Alloy
* Loki
* authentik
