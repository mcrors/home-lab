# Add jenkins agent
* Fix reverse proxy issue
* Add pi, potato and nuc node labels
* Move jenkins to pi node
* Set executors to 0

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

# Other Services
* paperless
* smpt server
* alert manager
* Alloy
* Loki
* authentik
* longhorn
* Rancher
