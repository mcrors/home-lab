Currently working on creating volumes. The current plan is to have a volume for each of the following:
- /config -> will come from the nfs share called sonarr.
- /data/media -> will come from the nfs share called media.
- /data/downloads -> will come from the nfs share called downloads.
    - This last one will not be created by this Chart, but instead will be managed by the transmission chart.

Transmission will download to the downloads share, and then Sonarr will copy the files to the media share.
A Cron job will be created to clean up the downloads share every 24 hours.
This will allow us to keep the downloads share smaller. And will keep the media files seperate for a future migration to a different server.

The next steps are to create the pv's and pvc's for the nfs shares.
Then to create the deployment and service for the sonarr chart.
Finally, we will create an ingress to be able to access the sonarr web interface.
