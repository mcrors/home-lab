# Find the password in proton pass
kubectl -n grafana create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<STRONG_PASSWORD>'
