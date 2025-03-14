* Switch sonarr config to iscsi
* Switch prowlarr config to iscsi
* Switch plex config to iscsi
* Create helm chart for radarr and install onto cluster
* restart iscsi initator and target on system restart
* periodic rescan on iscsi initator
    * this is so that we can see new luns if they are created on the target
* do login and discovery on iscsi initator on restart
* Add ssl certs to cluster workloads
    * This should be done via certmanager and letsEncrypts
    * For all interal services we will use *.houli.eu
* Add node exporter to all homelab machines
* Setup prometheus for metric scraping and storage
* Setup up Loki for log storage
* Setup Grafana for visualization
* Create Temperature monitoring and fan management app
* Backup volumes on iscsi Target

