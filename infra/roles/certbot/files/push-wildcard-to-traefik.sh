#!/usr/bin/env bash
set -euo pipefail

# Vars (keep in sync with your playbook vars)
KUBECONFIG="{{ kubeconfig_path }}"
NAMESPACE="{{ k8s_namespace }}"
SECRET="{{ secret_name }}"
CERT_DIR="{{ letsencrypt_live_dir }}"

# Push (create-or-update) the TLS Secret Traefik uses as default
KUBECONFIG="$KUBECONFIG" kubectl create secret tls "$SECRET" \
  -n "$NAMESPACE" \
  --cert="${CERT_DIR}/fullchain.pem" \
  --key="${CERT_DIR}/privkey.pem" \
  --dry-run=client -o yaml | KUBECONFIG="$KUBECONFIG" kubectl apply -f -
