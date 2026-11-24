#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# NULogic secret-guard — Claude Code hook
# Events: UserPromptSubmit (scan what the dev types)
#         PreToolUse       (stop Claude reading/writing secrets, and
#                           turn off question forms, whose answers
#                           can't be scanned)
# Exit 0 = allow | Exit 2 = block (stderr is shown)
# Logs WHICH rule fired, never the secret itself.
# ─────────────────────────────────────────────────────────────

# Behave the same on every machine, whatever the user's shell settings:
# byte-wise matching (no locale surprises or "illegal byte sequence") and
# no grep options from the environment.
export LC_ALL=C
unset GREP_OPTIONS GREP_COLOR GREP_COLORS POSIXLY_CORRECT CDPATH

# Helper tools (only present if the default grep/sed failed the installer's
# self-test) live in bin/ next to this script.
SECRET_GUARD_MANAGED=0   # the installer sets this to 1 for admin (--managed) installs
SG_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ "$SECRET_GUARD_MANAGED" = 1 ]; then
  # Admin install: ignore the user's PATH and overrides, so a fake grep put
  # earlier on PATH can't switch the checks off.
  PATH="$SG_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
else
  SECRET_GUARD_BIN="${SECRET_GUARD_BIN:-$SG_DIR/bin}"
  [ -d "$SECRET_GUARD_BIN" ] && PATH="$SECRET_GUARD_BIN:$PATH"
fi

LOG_FILE="${SECRET_GUARD_LOG:-$HOME/.claude/secret-guard.log}"
INPUT="$(cat)"

json_field() {
  printf '%s' "$INPUT" \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 | sed -E 's/.*"([^"]*)"$/\1/'
}

EVENT="$(json_field hook_event_name)"
TOOL="$(json_field tool_name)"

block() {
  local rule="$1"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '%s\tuser=%s\tevent=%s\ttool=%s\trule=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(whoami)" "${EVENT:-unknown}" \
    "${TOOL:--}" "$rule" >> "$LOG_FILE" 2>/dev/null

  if [ "$EVENT" = "UserPromptSubmit" ]; then
    echo "🔒 NULogic secret-guard blocked this message (rule: $rule)." >&2
    echo "It looks like it contains a key or credential. It was NOT sent to Claude." >&2
    echo "Replace the value with a placeholder like [REDACTED] and resend." >&2
  else
    echo "Blocked by NULogic secret-guard (rule: $rule): this action would read or" >&2
    echo "expose a credential or secret file. Do not retry or work around this." >&2
    echo "Ask the user for non-sensitive values or use placeholders instead." >&2
  fi
  exit 2
}

# ── 0. Question forms (PreToolUse on AskUserQuestion) ─────────
# Answers typed into Claude's question form go straight to Claude and never
# pass through UserPromptSubmit, so they can't be scanned. Make Claude ask
# in plain chat instead, where the reply is checked.
if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL" = "AskUserQuestion" ]; then
  echo "NULogic secret-guard has turned off question forms: answers typed there" >&2
  echo "skip the secret check. Ask the same question in plain chat instead." >&2
  exit 2
fi

# ── 1. Secret value patterns (case-sensitive) ────────────────
RULE_NAMES=(
  "aws-access-key"
  "anthropic-openai-key"
  "github-token"
  "slack-token"
  "google-api-key"
  "stripe-live-key"
  "private-key-block"
  "jwt"
  "db-url-with-password"
)
RULE_REGEX=(
  '(AKIA|ASIA)[0-9A-Z]{16}'
  'sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}'
  'gh[pousr]_[A-Za-z0-9]{36}'
  'xox[abprs]-[A-Za-z0-9-]{10,}'
  'AIza[0-9A-Za-z_-]{35}'
  '(sk|rk)_live_[0-9A-Za-z]{24,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
  '(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqps?)://[^:/"[:space:]]+:[^@"[:space:]]+@'
)

i=0
while [ $i -lt ${#RULE_NAMES[@]} ]; do
  if printf '%s' "$INPUT" | grep -Eq -- "${RULE_REGEX[$i]}"; then
    block "${RULE_NAMES[$i]}"
  fi
  i=$((i + 1))
done

# ── 2. Generic "name = long value" (case-insensitive) ────────
# Catches DB_PASSWORD=..., api_key: "...", client_secret=...
# Values shorter than 16 chars or starting with [ (e.g. [REDACTED]) pass.
if printf '%s' "$INPUT" | grep -Eiq \
  '(api[_-]?key|secret|passwd|password|access[_-]?token|auth[_-]?token)[\\"]*[[:space:]]*[:=][[:space:]]*[\\"]*[A-Za-z0-9/+_.-]{16,}'; then
  block "generic-credential-assignment"
fi

# ── 3. Secret files (PreToolUse only) ────────────────────────
# .env.example / .env.sample / .env.template are allowed.
if [ "$EVENT" = "PreToolUse" ]; then
  # Code that reads environment variables (process.env.X, import.meta.env.X,
  # Deno.env, Bun.env) is not a .env file, so drop it before matching.
  SANITIZED="$(printf '%s' "$INPUT" | sed -E \
    -e 's/\.env\.(example|sample|template)//g' \
    -e 's/(process|import\.meta|Deno|Bun)\.env//g')"
  if printf '%s' "$SANITIZED" | grep -Eq \
    '"(file_path|path|command|pattern)"[[:space:]]*:[[:space:]]*"[^"]*(\.env([^A-Za-z0-9]|$)|\.pem|\.p12|\.pfx|\.key([^A-Za-z]|$)|id_rsa|id_ed25519|\.aws/credentials|/secrets/|credentials\.json)'; then
    block "secret-file-access"
  fi
fi

exit 0
