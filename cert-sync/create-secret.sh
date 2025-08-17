#!/bin/bash
# This should be run on the machine where certbot is installed
export KUBECONFIG=$HOME/.kube/config-cert-sync
CERT_DIR="/etc/letsencrypt/live/houli.eu"

kubectl create secret tls houli-eu-wildcard \
  -n kube-system \
  --cert="${CERT_DIR}/fullchain.pem" \
  --key="${CERT_DIR}/privkey.pem" \
  --dry-run=client -o yaml | kubectl apply -f -
