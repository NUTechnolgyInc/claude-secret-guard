#!/usr/bin/env bash
# Builds install-secret-guard.sh: a single file with secret-guard.sh and
# test-secret-guard.sh embedded in installer-template.sh.
# Usage: bash build-installer.sh [version]   (default version: today's date)
#
# The report token is never stored in the repo. It's read at build time from
# SECRET_GUARD_REPORT_TOKEN or ~/.config/secret-guard-api/ingest-token; without
# one, the installer still works but sends no install reports.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(date +%Y.%m.%d)}"
OUT=install-secret-guard.sh
TOKEN_FILE="$HOME/.config/secret-guard-api/ingest-token"
TOKEN="${SECRET_GUARD_REPORT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -r "$TOKEN_FILE" ]; then TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"; fi
case "$TOKEN" in
  ''|*[!A-Za-z0-9_-]*) [ -n "$TOKEN" ] && { echo "Report token has unexpected characters." >&2; exit 1; }
                       echo "No report token found: this build won't send install reports." >&2 ;;
esac

for f in secret-guard.sh test-secret-guard.sh; do
  if grep -q '_SH_EOF__$' "$f"; then
    echo "$f contains a heredoc end marker used by the installer; rename it." >&2
    exit 1
  fi
done

awk -v ver="$VERSION" -v token="$TOKEN" '
  $0 == "@@SECRET_GUARD_SH@@" { while ((getline line < "secret-guard.sh") > 0) print line; next }
  $0 == "@@TEST_SH@@"         { while ((getline line < "test-secret-guard.sh") > 0) print line; next }
  /^REPORT_TOKEN=/ && token != "" { sub(/\[REDACTED\]/, token) }
  { gsub(/@@VERSION@@/, ver); print }
' installer-template.sh > "$OUT"

chmod 755 "$OUT"
bash -n "$OUT"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$OUT" > "$OUT.sha256"
else sha256sum "$OUT" > "$OUT.sha256"; fi
echo "Built $OUT (version $VERSION${TOKEN:+, with report token}) and $OUT.sha256"
