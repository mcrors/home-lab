#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
source "$root/config.env"

command -v helm >/dev/null || { echo "helm not found"; exit 1; }

if ! helm repo list | awk '{print $1}' | grep -q '^metallb$'; then
  helm repo add metallb https://metallb.github.io/metallb
fi
helm repo update

echo "Helm repos updated. (metallb present)"
