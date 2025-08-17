#!/usr/bin/env bash
set -euo pipefail
# Reload Nginx inside your reverse proxy container
docker exec nginx_reverse_proxy nginx -s reload
