#!/usr/bin/env bash
# Lists secret-guard install reports from the reporting API.
#
# Usage:
#   bash fetch-reports.sh                    latest 100 reports as a table
#   bash fetch-reports.sh --machines         current state per user + machine
#   bash fetch-reports.sh --json             raw JSON
#   bash fetch-reports.sh username=alice status=failed limit=20
#
# Filters: username, hostname, status (success|failed), event (install|uninstall), limit (max 500)
# Needs curl and jq. Reads the admin token from ~/.config/secret-guard-api/admin-token
# or the SECRET_GUARD_ADMIN_TOKEN environment variable.
set -euo pipefail

URL="${SECRET_GUARD_REPORT_URL:-https://secret-guard-api.vercel.app/api/installs}"
TOKEN_FILE="$HOME/.config/secret-guard-api/admin-token"

MODE=table
QUERY=()
for arg in "$@"; do
  case "$arg" in
    --json)     MODE=json ;;
    --machines) MODE=machines ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *=*)        QUERY+=("--data-urlencode" "$arg") ;;
    *)          echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done
[ "$MODE" = machines ] && QUERY+=("--data-urlencode" "limit=500")

TOKEN="${SECRET_GUARD_ADMIN_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -r "$TOKEN_FILE" ]; then TOKEN="$(cat "$TOKEN_FILE")"; fi
[ -n "$TOKEN" ] || { echo "No admin token. Put it in $TOKEN_FILE or set SECRET_GUARD_ADMIN_TOKEN." >&2; exit 1; }

RESPONSE="$(curl -sS --fail-with-body --max-time 15 -G "$URL" \
  -H "Authorization: Bearer $TOKEN" ${QUERY[@]+"${QUERY[@]}"})" || {
  echo "Request failed: $RESPONSE" >&2; exit 1; }

case "$MODE" in
  json)
    printf '%s\n' "$RESPONSE" | jq . ;;
  table)
    printf '%s\n' "$RESPONSE" | jq -r '
      (["RECEIVED (UTC)", "EVENT", "STATUS", "USER", "MACHINE", "OS", "VER", "TESTS"] | @tsv),
      (.installs[] | [
        (.received_at[:19] | sub("T"; " ")), .event, .status, .username, .hostname,
        "\(.os) \(.os_version // "")", .script_version,
        "\(.tests_passed)/\(.tests_passed + .tests_failed)"
      ] | @tsv)' | column -t -s $'\t'
    printf '%s\n' "$RESPONSE" | jq -r '"\n\(.count) report(s)"' ;;
  machines)
    # Newest report per user + machine tells you whether it's installed there now.
    printf '%s\n' "$RESPONSE" | jq -r '
      (["USER", "MACHINE", "STATE", "VER", "LAST SEEN (UTC)"] | @tsv),
      (.installs | group_by(.username + "|" + .hostname)[] | max_by(.received_at) | [
        .username, .hostname,
        (if .event == "install" and .status == "success" then "installed"
         elif .event == "uninstall" and .status == "success" then "removed"
         else "\(.event) failed" end),
        .script_version, (.received_at[:19] | sub("T"; " "))
      ] | @tsv)' | column -t -s $'\t' ;;
esac
