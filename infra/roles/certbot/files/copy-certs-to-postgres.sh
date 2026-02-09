#!/usr/bin/env bash
set -euo pipefail

# Config (override via env if you like)
PG_CONT="${PG_CONT:-postgres}"                         # container name
LE_DIR="${LE_DIR:-/etc/letsencrypt/live/houli.eu}"     # cert-manager/LE lineage
DST_DIR="${DST_DIR:-/mnt/postgres/certs}"              # mounted into the PG container
PG_UID="${PG_UID:-999}"                                # postgres user in the image

# Ensure destination dir exists with tight perms
install -d -o "$PG_UID" -g "$PG_UID" -m 0700 "$DST_DIR"

# Copy cert + key with correct ownership and modes
install -o "$PG_UID" -g "$PG_UID" -m 0644 "$LE_DIR/fullchain.pem" "$DST_DIR/server.crt"
install -o "$PG_UID" -g "$PG_UID" -m 0600 "$LE_DIR/privkey.pem"   "$DST_DIR/server.key"

# Zero-downtime reload (no DB creds needed)
docker kill --signal=HUP "$PG_CONT" >/dev/null
echo "Postgres reloaded TLS (SIGHUP)."
