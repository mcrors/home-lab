# If Plex does not see itself as a self hosted server

* Check the following to see if you have successfully claimed the server
kubectl exec -it  $(kc get pods -n plex | awk 'NR>1 {print $1}') -n plex -- curl -s http://localhost:32400/identity
* Check the claimed value
* If not, delete this settings file
rm -rf /config/Library/Application\ Support/Plex\ Media\ Server/Preferences.xml
* Generate a new claim from the plex website
https://account.plex.tv/en/claim
* Add the claim to the secret in values.yaml
* delete and re-install the helm chart


