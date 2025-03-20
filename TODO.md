# Media Setup
* Switch plex config to iscsi
* Create helm chart for radarr and install onto cluster
* Install and configer homarr
* Install and configer JellyFin
    * Once this is working, it will require side loading the client to the TV

# iscsi
* Backup volumes on iscsi Target
* periodic rescan on iscsi initator
    * this is so that we can see new luns if they are created on the target
* do login and discovery on iscsi initator on restart

# Security
* Add ssl certs to cluster workloads
    * This should be done via certmanager and letsEncrypts
    * For all interal services we will use *.houli.eu

# Monitoring
* Add node exporter to all homelab machines
* Add cron exporter to iscsi target
* Setup prometheus for metric scraping and storage
* Setup Grafana for visualization
* Create Temperature monitoring and fan management app
* Setup up Loki for log storage

