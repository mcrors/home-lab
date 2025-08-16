#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
source "$root/config.env"

KCTX_ARGS=()
if [[ -n "${KUBECTL_CONTEXT:-}" ]]; then
  KCTX_ARGS=(--context "$KUBECTL_CONTEXT")
fi

echo "This will remove MetalLB (Helm release) and its CRs in namespace $NAMESPACE."
read -rp "Type 'yes' to continue: " ans
[[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }

# Remove test artifacts if present
kubectl "${KCTX_ARGS[@]}" delete svc lb-test deploy lb-test --ignore-not-found=true

# Remove our CRs
kubectl "${KCTX_ARGS[@]}" -n "$NAMESPACE" delete l2advertisement "$L2_ADV_NAME" --ignore-not-found=true
kubectl "${KCTX_ARGS[@]}" -n "$NAMESPACE" delete ipaddresspool "$POOL_NAME" --ignore-not-found=true

# Helm uninstall
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true

echo "MetalLB release removed."
echo "Note: CRDs stay unless you delete them cluster-wide (not recommended if you’ll reinstall)."
