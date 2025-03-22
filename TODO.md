# Media Setup
* Expand the volume for transmission
    * Grab the claim id
    * delete the config file which holds the claim info
    * update the pv and pvc for this volume in the helm chart
    * re-deploy the helm chart
* Create helm chart for radarr and install onto cluster
* Install and configer homarr
* Install and configer JellyFin
    * Once this is working, it will require side loading the client to the TV


# iscsi
* periodic rescan on iscsi initator
    * this is so that we can see new luns if they are created on the target
* do login and discovery on iscsi initator on restart


# Security
* Add ssl certs to cluster workloads
    * This should be done via certmanager and letsEncrypts
    * For all interal services we will use *.houli.eu
* Is there a way to add TLS to the exporters to prometheus

# Monitoring
* Add node exporter to all homelab machines
* Add cron exporter to iscsi target
* Add cron exporter to iscsi initator
* Add lvm exporter to iscsi target
* Setup prometheus for metric scraping and storage
    * This will go on the iscsi server
    * We will have a seperate physical drive for this data
* Setup Grafana for visualization
    * This may as well go on the iscsi server too
* Create Temperature monitoring and fan management app
* Setup up Loki for log storage


# Backup volumes on iscsi Target
* Clean up log file
    * Log to the same file for a week, then truncate the file
    * maybe do this in a cron job
* Clean up the backup files
    * delete files older that 3 weeks
    * maybe do this in a cron job


