# Media Setup
* Install and configer homarr
* Install and configer JellyFin
    * Once this is working, it will require side loading the client to the TV
* Move prowlarr, sonarr and radarr to a single helm chart with 3 different value files

# Security
* Add ssl certs to cluster workloads
    * This should be done via certmanager and letsEncrypts
    * For all interal services we will use *.houli.eu
* Is there a way to add TLS to the exporters to prometheus

# Monitoring
* add lib-hp-01 to monitoring
* Add cron exporter to all hosts
* Add lvm exporter to iscsi target
* Create Temperature monitoring and fan management app
* Setup up Loki for log storage
* Create grafana dashboards for:
    * host health -> green or red depending on if the host is reachable
    * Cron jobs -> List of cron jobs with last 10 run results
* Set up alerting for specific metrics
* add cAdvisor:
    * exporter
    * dashboard
* Setup Uptime Kuma for service and host monitoring and notification

* Check that the volumes are mounted on fstab

# Backup volumes on iscsi Target
* Clean up log file
    * Log to the same file for a week, then truncate the file
    * maybe do this in a cron job
* Clean up the backup files
    * delete files older that 3 weeks
    * maybe do this in a cron job

# Self hosted container registry
* Determine which registry to use
* Set up automated vendoring of specific images
    * This should include periodic checks for updates

# Clean up ansible playbooks

# Redundancy
* Install MetalLB as a daemon set to prevent relying on a single ip for service discovery
    * the ip that all the k3s services were assigned to in pihole no longer worked
      and I was unable to reach any of my services
# Other Services
* Look into paperless service
