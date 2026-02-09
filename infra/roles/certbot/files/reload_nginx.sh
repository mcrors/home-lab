#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[certbot-nginx-restart]"

CONTAINER="nginx_reverse_proxy"

echo "${LOG_PREFIX} $(date -Is) starting"
echo "${LOG_PREFIX} container=${CONTAINER}"

# Ensure docker exists
if ! command -v docker >/dev/null 2>&1; then
  echo "${LOG_PREFIX} ERROR: docker not found"
  exit 127
fi

# Ensure container is running
if ! docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER}"; then
  echo "${LOG_PREFIX} ERROR: container '${CONTAINER}' not running"
  echo "${LOG_PREFIX} running containers:"
  docker ps --format 'table {{.Names}}\t{{.Status}}'
  exit 1
fi

# restart nginx container
docker restart "${CONTAINER}"

echo "${LOG_PREFIX} $(date -Is) done"
