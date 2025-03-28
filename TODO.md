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
* Add cron exporter to iscsi target
* Add cron exporter to iscsi initator
* Add lvm exporter to iscsi target
* Create Temperature monitoring and fan management app
* Setup up Loki for log storage

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
