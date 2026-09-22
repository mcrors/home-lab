#!/bin/sh
# Bring Pi-hole's gravity database into line with the mounted list files.
#
# Pi-hole reads /etc/pihole/adlists.list and /etc/pihole/whitelist.txt exactly
# once, in gravity.sh's migrate_to_database, which only runs when gravity.db does
# not exist. After that the database is the only source of truth and an edit to
# the repo reaches the mounted files and stops there. Every subscription on a
# running instance still carries the comment "Migrated from /etc/pihole/adlists.list".
#
# Those mounted files are ConfigMaps, so Kubernetes keeps them current for free.
# This script reconciles the database against them through FTL's REST API, which
# is the interface Pi-hole supports. Writing the SQLite tables directly would work
# and would depend on a schema the maintainers treat as internal.
#
# Run with --dry-run to print the differences and change nothing.
#
# Exits non-zero on any API failure so the playbook stops rather than continuing
# with a half-applied list.

set -eu

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

API="http://localhost/api"
ADLIST_FILE=/etc/pihole/adlists.list
ALLOW_FILE=/etc/pihole/whitelist.txt
COMMENT="Managed by the home-lab pihole role"
WORK=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$WORK'; [ -n \"\${SID:-}\" ] && curl -s -X DELETE -H \"sid: \$SID\" '$API/auth' >/dev/null 2>&1 || true" EXIT

# cli_pw is a password file FTL writes for processes running on the box, enabled
# by webserver.api.cli_pw. Using it means this script needs no admin secret.
SID=$(curl -sf -X POST "$API/auth" -H 'Content-Type: application/json' \
        --data "$(jq -n --arg p "$(cat /etc/pihole/cli_pw)" '{password:$p}')" \
      | jq -r '.session.sid // empty')
[ -n "$SID" ] || { echo "reconcile: authentication failed" >&2; exit 1; }

api() {
  _method=$1; _path=$2; shift 2
  curl -sf -X "$_method" -H "sid: $SID" -H 'Content-Type: application/json' "$API$_path" "$@"
}

# Strip comments and blank lines so the file can carry both.
clean() { sed 's/#.*//' "$1" | tr -d '\r' | awk 'NF'; }

changed=0

reconcile() {
  _what=$1; _file=$2; _get=$3; _add=$4; _addkey=$5; _jqpath=$6; _delitem=$7; _delpath=$8

  clean "$_file" | sort -u > "$WORK/desired"
  api GET "$_get" | jq -r "$_jqpath" | sort -u > "$WORK/current"

  comm -23 "$WORK/desired" "$WORK/current" > "$WORK/add"
  comm -13 "$WORK/desired" "$WORK/current" > "$WORK/remove"

  _na=$(wc -l < "$WORK/add" | tr -d ' ')
  _nr=$(wc -l < "$WORK/remove" | tr -d ' ')
  echo "  $_what: $(wc -l < "$WORK/desired" | tr -d ' ') wanted, $(wc -l < "$WORK/current" | tr -d ' ') present, $_na to add, $_nr to remove"
  sed 's/^/    + /' "$WORK/add"
  sed 's/^/    - /' "$WORK/remove"

  [ "$_na" -eq 0 ] && [ "$_nr" -eq 0 ] && return 0
  changed=1
  [ "$DRY_RUN" -eq 1 ] && return 0

  if [ "$_na" -gt 0 ]; then
    jq -Rn --arg c "$COMMENT" --arg k "$_addkey" \
      '[inputs] as $items | {($k): $items, comment:$c, groups:[0], enabled:true}' \
      < "$WORK/add" > "$WORK/payload"
    api POST "$_add" --data @"$WORK/payload" \
      | jq -e '.processed.errors | length == 0' >/dev/null \
      || { echo "reconcile: failed adding to $_what" >&2; exit 1; }
  fi

  if [ "$_nr" -gt 0 ]; then
    # shellcheck disable=SC2016
    jq -Rn --argjson t "$_delitem" '[inputs | {item:.} + $t]' < "$WORK/remove" > "$WORK/payload"
    api POST "$_delpath" --data @"$WORK/payload" >/dev/null \
      || { echo "reconcile: failed removing from $_what" >&2; exit 1; }
  fi
}

[ "$DRY_RUN" -eq 1 ] && echo "reconcile: dry run, nothing will be changed"

reconcile "adlists" "$ADLIST_FILE" \
  "/lists?type=block" "/lists?type=block" \
  "address" '.lists[].address' '{"type":"block"}' "/lists:batchDelete"

reconcile "allowlist" "$ALLOW_FILE" \
  "/domains/allow/exact" "/domains/allow/exact" \
  "domain" '.domains[].domain' '{"type":"allow","kind":"exact"}' "/domains:batchDelete"

if [ "$changed" -eq 0 ]; then
  echo "reconcile: database already matches the mounted files"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "reconcile: changes above were NOT applied"
else
  echo "reconcile: applied"
fi
