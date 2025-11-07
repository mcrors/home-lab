# Redo physical setup and wiring
* Make plan for bringing everything offline and backup again
    * Might want to add another 1U unit to hold ssd's for k3s nodes (for longhorn)
    * Install new pi 5 NAS's
    * Will want to re do wiring/cable management
    * Ansiblize some/most/all of this

# Media Setup
* Install and configer homarr
* Create mechanism for using ffprobe and ffmpeg to transcode to default codecs
    * cron job on k3s that periodically checks for new content and transcodes
    * Web app to transcode content without waiting for cron job
* Move prowlarr, sonarr and radarr to a single helm chart with 3 different value files

# Security
* move plex to metallb and https (maybe)
* pi hole admin interface behind nginx with certificate
* pi hole to k3s cluster
* certificate added to omv
* Add authentik
* Update helm chart ClusterRoles to Roles
* Is there a way to add TLS to the exporters to prometheus

# Monitoring
* Setup alerts for disk space
* Set up notifications
* Update blackbox exporter for endpoints that require auth
* Setup up Loki for log storage
* Create grafana dashboards for:
    * Cron jobs -> List of cron jobs with last 10 run results
* Set up alerting for specific metrics
* add cAdvisor:
    * exporter
    * dashboard
* Add alloy
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

# Automation
* Clean up ansible playbook
* Add jenkins agent

# Other Services
* paperless
* smpt server
* alert manager
* Alloy
* Loki
* authentik
* longhorn
