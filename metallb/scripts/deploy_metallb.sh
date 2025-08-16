#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
source "$root/config.env"

# Optional context pin
declare -a KCTX_ARGS=()
if [[ -n "${KUBECTL_CONTEXT:-}" ]]; then
  KCTX_ARGS=(--context "$KUBECTL_CONTEXT")
fi

# Basic guards
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v helm >/dev/null || { echo "helm not found"; exit 1; }
command -v envsubst >/dev/null || { echo "envsubst not found (install gettext)"; exit 1; }

echo "==> Cluster:"
kubectl ${KCTX_ARGS[@]:-} cluster-info || true
kubectl ${KCTX_ARGS[@]:-} get nodes -o wide

echo "==> Namespace: $NAMESPACE"
kubectl ${KCTX_ARGS[@]:-} get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl ${KCTX_ARGS[@]:-} create ns "$NAMESPACE"

# Optional memberlist secret (helps L2 membership gossip in some setups)
if [[ "${MEMBERLIST_SECRET_ENABLED}" == "true" ]]; then
  if ! kubectl ${KCTX_ARGS[@]:-} -n "$NAMESPACE" get secret memberlist >/dev/null 2>&1; then
    echo "==> Creating memberlist secret"
    kubectl ${KCTX_ARGS[@]:-} -n "$NAMESPACE" create secret generic memberlist \
      --from-literal=secretkey="$(openssl rand -base64 128)"
  else
    echo "==> memberlist secret already exists"
  fi
fi

# Install/upgrade MetalLB
echo "==> Installing/upgrading MetalLB"
declare -a VER_ARGS=()
[[ -n "${CHART_VERSION}" ]] && VER_ARGS=(--version "$CHART_VERSION")

helm upgrade --install "$RELEASE_NAME" metallb/metallb \
  -n "$NAMESPACE" \
  -f "$root/helm/values.yaml" \
  ${VER_ARGS[@]:-}

echo "==> Waiting for controller and speaker to be ready (timeout ${WAIT_TIMEOUT_SECONDS}s)"
kubectl ${KCTX_ARGS[@]:-} -n "$NAMESPACE" rollout status deploy/metallb-controller --timeout="${WAIT_TIMEOUT_SECONDS}s"
kubectl ${KCTX_ARGS[@]:-} -n "$NAMESPACE" rollout status ds/metallb-speaker --timeout="${WAIT_TIMEOUT_SECONDS}s"

echo "==> Ensuring CRDs are present"
for crd in ipaddresspools.metallb.io l2advertisements.metallb.io; do
  kubectl ${KCTX_ARGS[@]:-} get crd "$crd" >/dev/null
done

# Render and apply manifests
echo "==> Applying IPAddressPool + L2Advertisement"
tmpdir="$(mktemp -d)"
for f in "$root/manifests/"*.tmpl.yaml; do
  out="$tmpdir/$(basename "$f" .tmpl.yaml).yaml"
  NAMESPACE="$NAMESPACE" POOL_NAME="$POOL_NAME" POOL_ADDRESSES="$POOL_ADDRESSES" L2_ADV_NAME="$L2_ADV_NAME" \
    envsubst < "$f" > "$out"
  kubectl ${KCTX_ARGS[@]:-} apply -f "$out"
done

echo "==> Current MetalLB state"
kubectl ${KCTX_ARGS[@]:-} -n "$NAMESPACE" get pods -o wide
kubectl ${KCTX_ARGS[@]:-} -n "$NAMESPACE" get ipaddresspools,l2advertisements

# Optional smoke test
if [[ "${SMOKE_TEST_ENABLED}" == "true" ]]; then
  echo "==> Smoke test: creating lb-test (nginxdemos/hello)"
  kubectl ${KCTX_ARGS[@]:-} create deploy lb-test --image=nginxdemos/hello:plain-text --replicas=1 >/dev/null 2>&1 || true
  kubectl ${KCTX_ARGS[@]:-} expose deploy lb-test --port=80 --type=LoadBalancer >/dev/null 2>&1 || true

  echo "==> Waiting for External IP from pool ${POOL_ADDRESSES}"
  end=$((SECONDS + 120))
  ext_ip=""
  while [[ $SECONDS -lt $end ]]; do
    ext_ip="$(kubectl ${KCTX_ARGS[@]:-} get svc lb-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ "$ext_ip" =~ ^192\.168\.1\.25[0-4]$ ]]; then
      break
    fi
    sleep 2
  done

  if [[ -n "$ext_ip" ]]; then
    echo "✅ Smoke test External IP: $ext_ip"
    echo "Try: curl http://$ext_ip/"
  else
    echo "⚠️  Smoke test did not obtain an IP from ${POOL_ADDRESSES} within 120s"
    kubectl ${KCTX_ARGS[@]:-} get svc lb-test -o wide || true
  fi

  echo "Cleanup when done:"
  echo "  kubectl delete svc lb-test deploy lb-test"
fi

echo "==> Done."
