#!/usr/bin/env bash
# If this file was saved with Windows (CRLF) line endings, re-run a cleaned copy. #
if [ -n "${BASH_VERSION:-}" ] && [ -f "$0" ] && grep -q "$(printf '\r')" "$0" 2>/dev/null; then _lf="${TMPDIR:-/tmp}/install-secret-guard.$$.sh"; tr -d '\r' < "$0" > "$_lf" && _SG_LF_COPY="$_lf" exec bash "$_lf" "$@"; fi #
# ─────────────────────────────────────────────────────────────
# NULogic secret-guard installer (version @@VERSION@@)
# Installs the Claude Code secret-guard hook for the current user.
# Run "bash install-secret-guard.sh --help" for options.
#
# It tries hard not to give up: missing tools are set up, a failing
# self-test is diagnosed and fixed where possible, then re-run.
# ─────────────────────────────────────────────────────────────
# GENERATED FILE: edit installer-template.sh, secret-guard.sh or
# test-secret-guard.sh, then run build-installer.sh.

set -u

VERSION="@@VERSION@@"
REPORT_URL="${SECRET_GUARD_REPORT_URL:-https://secret-guard-api.vercel.app/api/installs}"
REPORT_TOKEN="${SECRET_GUARD_REPORT_TOKEN:-[REDACTED]}"

CLAUDE_DIR="$HOME/.claude"
HOOK_DIR="$CLAUDE_DIR/hooks"
HOOK_PATH="$HOOK_DIR/secret-guard.sh"
BIN_DIR="$HOOK_DIR/bin"   # helper tools set up by this installer, only when needed
# Deny rules this installer added (so uninstall leaves the user's own rules alone)
RULES_RECORD="$HOOK_DIR/secret-guard.added-rules"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_CMD='bash "$HOME/.claude/hooks/secret-guard.sh"'
HOOK_MATCHER='Bash|Read|Write|Edit|MultiEdit|Grep|AskUserQuestion'
DENY_RULES=(
  'Read(**/.env)'
  'Read(**/*.pem)'
  'Read(**/*.key)'
  'Read(**/secrets/**)'
  'Read(~/.aws/credentials)'
)

# jq is downloaded from its official GitHub release when neither jq nor
# python3 is available. Checksums are from the release's sha256sum.txt.
JQ_VERSION="1.7.1"
JQ_BASE_URL="https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION"
jq_sha256() {
  case "$1" in
    jq-macos-arm64)       echo 0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a ;;
    jq-macos-amd64)       echo 4155822bbf5ea90f5c79cf254665975eb4274d426d0709770c21774de5407443 ;;
    jq-linux-amd64)       echo 5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5 ;;
    jq-linux-arm64)       echo 4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5 ;;
    jq-linux-armhf)       echo 46d18f115cca638efed22b90342d52a84a25ab1bef570551d3a16f7eb065c298 ;;
    jq-linux-i386)        echo bc473fd4b385789e9ce3d02a4c8df74dc988a34b20fe4e1a80da997eb360b599 ;;
    jq-windows-amd64.exe) echo 7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab ;;
    jq-windows-i386.exe)  echo e4efdd6a2c463ae714ed98fd5e874fe834a3a2380e17885bd4cda1c49e5166df ;;
  esac
}

usage() {
  cat <<'EOF'
NULogic secret-guard installer

  bash install-secret-guard.sh               install or update
  bash install-secret-guard.sh --uninstall   remove the hook and its rules
  bash install-secret-guard.sh --no-report   don't send the install report
  bash install-secret-guard.sh --yes         approve tool installs without asking

Works on macOS, Linux, and Windows via Git Bash or WSL. Missing tools (jq,
GNU grep/sed) are set up automatically; anything that needs sudo or a
package manager is asked about first unless you pass --yes.
EOF
}

MODE=install
SEND_REPORT=1
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    --no-report) SEND_REPORT=0 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

# ── Don't install for root by mistake ────────────────────────
if [ "$(id -u 2>/dev/null)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  echo "This installs for your own user, so it shouldn't run with sudo."
  if [ -f "$0" ] && command -v sudo >/dev/null 2>&1; then
    echo "Re-running as $SUDO_USER..."
    exec sudo -u "$SUDO_USER" -H bash "$0" "$@"
  fi
  echo "Run it again without sudo: bash install-secret-guard.sh" >&2
  exit 1
fi

TESTS_PASSED=0
TESTS_FAILED=0
FIXES=""            # fixes applied on this machine, shown at the end and reported
JSON_TOOL=""
JQ_BIN=""
DOWNLOADED_JQ=""
SHIM_GREP=""
SHIM_SED=""

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t secret-guard 2>/dev/null)"
if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
  TMP_DIR="${TMPDIR:-/tmp}/secret-guard.$$"
  mkdir -p "$TMP_DIR" || { echo "Can't create a temporary folder." >&2; exit 1; }
fi
cleanup() {
  rm -rf "$TMP_DIR"
  if [ -n "${_SG_LF_COPY:-}" ]; then rm -f "$_SG_LF_COPY"; fi
}
trap cleanup EXIT

say()   { printf '%s\n' "$*"; }
step()  { printf '\n▸ %s\n' "$*"; }
ok()    { printf '  ✓ %s\n' "$*"; }
warn()  { printf '  ! %s\n' "$*"; }
fixed() { printf '  ↻ %s\n' "$*"; FIXES="${FIXES:+$FIXES; }$*"; }

# ── Basic tools for the installer's own use ──────────────────
# The installer picks a grep and sed that actually work, so a broken one
# earlier on PATH can't break the installer itself.
first_working_grep() {
  local g
  for g in grep /usr/bin/grep /bin/grep ggrep /opt/homebrew/bin/ggrep /usr/local/bin/ggrep; do
    command -v "$g" >/dev/null 2>&1 || continue
    [ "$(printf 'a"bc"d\n' | "$g" -oE '"[^"]*"' 2>/dev/null)" = '"bc"' ] && { echo "$g"; return 0; }
  done
  return 1
}
first_working_sed() {
  local s
  for s in sed /usr/bin/sed /bin/sed gsed /opt/homebrew/bin/gsed /usr/local/bin/gsed; do
    command -v "$s" >/dev/null 2>&1 || continue
    [ "$(printf 'abc\n' | "$s" -E 's/(b)/[\1]/' 2>/dev/null)" = 'a[b]c' ] && { echo "$s"; return 0; }
  done
  return 1
}
G="$(first_working_grep)" || G=""
S="$(first_working_sed)" || S=""

# ── Identify the machine ─────────────────────────────────────
USER_NAME="$(whoami 2>/dev/null || id -un 2>/dev/null || echo unknown)"
HOST_NAME="$(hostname 2>/dev/null || uname -n)"
ARCH="$(uname -m 2>/dev/null)"
case "$(uname -s)" in
  Darwin)
    OS=macos
    OS_VERSION="$(sw_vers -productVersion 2>/dev/null)" ;;
  Linux)
    case "$(cat /proc/version 2>/dev/null)" in *[Mm]icrosoft*) OS=wsl ;; *) OS=linux ;; esac
    OS_VERSION="$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")" ;;
  MINGW*|MSYS*|CYGWIN*)
    OS=windows-gitbash
    OS_VERSION="$(uname -r)" ;;
  *)
    OS="$(uname -s)"
    OS_VERSION="$(uname -r)" ;;
esac
CLAUDE_VERSION="$(claude --version 2>/dev/null | head -1)"

# ── Asking, sudo, downloads ──────────────────────────────────
has_tty() { { exec 3</dev/tty; } 2>/dev/null || return 1; exec 3<&-; return 0; }

confirm() {  # question → 0 if the user agrees
  [ "$ASSUME_YES" = 1 ] && return 0
  has_tty || return 1
  local reply
  printf '  ? %s [Y/n] ' "$1" > /dev/tty
  read -r reply < /dev/tty || return 1
  case "$reply" in ""|y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}

SUDO=""
get_sudo() {  # sets SUDO to "" (root) or "sudo"; returns 1 if not possible
  if [ "$(id -u 2>/dev/null)" = 0 ]; then SUDO=""; return 0; fi
  command -v sudo >/dev/null 2>&1 || return 1
  if sudo -n true 2>/dev/null; then SUDO="sudo"; return 0; fi
  has_tty || return 1
  say "    (sudo may ask for your computer login)"
  sudo -v < /dev/tty && { SUDO="sudo"; return 0; }
  return 1
}

http_get() {  # url, destination file
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 30 -t 3 -O "$2" "$1"
  else
    return 1
  fi
}

http_post_json() {  # url, payload
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -X POST \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $REPORT_TOKEN" \
      --data "$2" "$1" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 10 -t 2 -O /dev/null --header='Content-Type: application/json' \
      --header="Authorization: Bearer $REPORT_TOKEN" --post-data="$2" "$1"
  else
    return 1
  fi
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1
  fi
}

# Installs packages with whatever package manager this machine has.
# $1 = what for (shown to the user); then "manager:package list" entries.
install_packages() {
  local why="$1" pm="" pkgs="" entry status
  shift
  for entry in "$@"; do
    case "$entry" in
      brew:*)   command -v brew    >/dev/null 2>&1 && { pm=brew;   pkgs="${entry#brew:}"; break; } ;;
      apt:*)    command -v apt-get >/dev/null 2>&1 && { pm=apt;    pkgs="${entry#apt:}"; break; } ;;
      dnf:*)    command -v dnf     >/dev/null 2>&1 && { pm=dnf;    pkgs="${entry#dnf:}"; break; } ;;
      yum:*)    command -v yum     >/dev/null 2>&1 && { pm=yum;    pkgs="${entry#yum:}"; break; } ;;
      apk:*)    command -v apk     >/dev/null 2>&1 && { pm=apk;    pkgs="${entry#apk:}"; break; } ;;
      pacman:*) command -v pacman  >/dev/null 2>&1 && { pm=pacman; pkgs="${entry#pacman:}"; break; } ;;
      zypper:*) command -v zypper  >/dev/null 2>&1 && { pm=zypper; pkgs="${entry#zypper:}"; break; } ;;
      winget:*) command -v winget  >/dev/null 2>&1 && { pm=winget; pkgs="${entry#winget:}"; break; } ;;
      scoop:*)  command -v scoop   >/dev/null 2>&1 && { pm=scoop;  pkgs="${entry#scoop:}"; break; } ;;
    esac
  done
  [ -n "$pm" ] || { warn "No supported package manager found to install what's needed for $why."; return 1; }
  confirm "Install $pkgs with $pm (needed for $why)?" || { warn "Skipped installing $pkgs."; return 1; }

  # shellcheck disable=SC2086
  case "$pm" in
    brew)   HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install $pkgs ;;
    apt)    get_sudo && { $SUDO apt-get install -y $pkgs || { $SUDO apt-get update && $SUDO apt-get install -y $pkgs; }; } ;;
    dnf)    get_sudo && $SUDO dnf install -y $pkgs ;;
    yum)    get_sudo && $SUDO yum install -y $pkgs ;;
    apk)    get_sudo && $SUDO apk add $pkgs ;;
    pacman) get_sudo && $SUDO pacman -S --noconfirm $pkgs ;;
    zypper) get_sudo && $SUDO zypper --non-interactive install $pkgs ;;
    winget) winget install --silent --accept-package-agreements --accept-source-agreements --id $pkgs ;;
    scoop)  scoop install $pkgs ;;
  esac > "$TMP_DIR/pkg.log" 2>&1
  status=$?
  if [ $status -ne 0 ]; then
    warn "Installing $pkgs with $pm failed. Last lines:"
    tail -3 "$TMP_DIR/pkg.log" | while IFS= read -r l; do say "      $l"; done
    return 1
  fi
  hash -r 2>/dev/null
  fixed "Installed $pkgs with $pm"
  return 0
}

# ── Install report (never blocks the install) ────────────────
json_str() { printf '"%s"' "$(printf '%s' "$1" | "${S:-sed}" -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r\t')"; }

report_enabled() {
  [ "$SEND_REPORT" = 1 ] || return 1
  case "$REPORT_URL" in *'[YOUR-API]'*) return 1 ;; esac
  case "$REPORT_TOKEN" in *'[REDACTED]'*) return 1 ;; esac
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

report() {  # status, detail
  report_enabled || return 0
  local detail="${2:-}" payload
  [ -n "$FIXES" ] && detail="$detail (fixes: $FIXES)"
  payload="{\"event\":$(json_str "$MODE"),\"status\":$(json_str "$1"),\"detail\":$(json_str "$detail")"
  payload="$payload,\"script_version\":$(json_str "$VERSION"),\"username\":$(json_str "$USER_NAME")"
  payload="$payload,\"hostname\":$(json_str "$HOST_NAME"),\"os\":$(json_str "$OS")"
  payload="$payload,\"os_version\":$(json_str "$OS_VERSION"),\"claude_version\":$(json_str "$CLAUDE_VERSION")"
  payload="$payload,\"tests_passed\":${TESTS_PASSED:-0},\"tests_failed\":${TESTS_FAILED:-0}"
  payload="$payload,\"timestamp\":$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")}"
  if http_post_json "$REPORT_URL" "$payload"; then
    ok "Sent $MODE report"
  else
    warn "Couldn't reach the report server. The $MODE itself is unaffected."
  fi
}

fail() {
  printf '\n✗ %s\n' "$1" >&2
  report failed "$1"
  exit 1
}

# ── JSON tool: jq, python3, or a downloaded jq ───────────────
skipped_tool() {  # for testing: SECRET_GUARD_PRETEND_MISSING="jq python3"
  case " ${SECRET_GUARD_PRETEND_MISSING:-} " in *" $1 "*) return 0 ;; esac
  return 1
}

python_usable() {
  skipped_tool python3 && return 1
  command -v python3 >/dev/null 2>&1 || return 1
  # On a Mac without developer tools, /usr/bin/python3 is a stub that opens an
  # install dialog instead of running, so don't touch it.
  if [ "$OS" = macos ] && [ "$(command -v python3)" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then
    return 1
  fi
  python3 -c 'import json' >/dev/null 2>&1
}

pick_json_tool() {
  JSON_TOOL=""; JQ_BIN=""
  if [ -n "${SECRET_GUARD_JSON_TOOL:-}" ]; then
    JSON_TOOL="$SECRET_GUARD_JSON_TOOL"; JQ_BIN=jq; return 0
  fi
  if ! skipped_tool jq && command -v jq >/dev/null 2>&1 && jq --version >/dev/null 2>&1; then
    JSON_TOOL=jq; JQ_BIN=jq; return 0
  fi
  local own
  for own in "$BIN_DIR/jq" "$BIN_DIR/jq.exe"; do
    if [ -x "$own" ] && "$own" --version >/dev/null 2>&1; then JSON_TOOL=jq; JQ_BIN="$own"; return 0; fi
  done
  if python_usable; then JSON_TOOL=python3; return 0; fi
  return 1
}

download_jq() {
  local asset name="jq" expected actual
  case "$(uname -s)-$ARCH" in
    Darwin-arm64)                              asset=jq-macos-arm64 ;;
    Darwin-x86_64)                             asset=jq-macos-amd64 ;;
    Linux-x86_64|Linux-amd64)                  asset=jq-linux-amd64 ;;
    Linux-aarch64|Linux-arm64)                 asset=jq-linux-arm64 ;;
    Linux-armv7l|Linux-armv6l)                 asset=jq-linux-armhf ;;
    Linux-i686|Linux-i386)                     asset=jq-linux-i386 ;;
    MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64) asset=jq-windows-amd64.exe; name=jq.exe ;;
    MINGW*-i686|MSYS*-i686|CYGWIN*-i686)       asset=jq-windows-i386.exe;  name=jq.exe ;;
    *) warn "No ready-made jq download for $(uname -s) $ARCH."; return 1 ;;
  esac
  say "    Downloading jq $JQ_VERSION from github.com/jqlang/jq ..."
  if ! http_get "$JQ_BASE_URL/$asset" "$TMP_DIR/$name"; then
    warn "Couldn't download jq (no internet, or a proxy is blocking github.com)."
    return 1
  fi
  expected="$(jq_sha256 "$asset")"
  if ! actual="$(sha256_of "$TMP_DIR/$name")"; then
    warn "No SHA-256 tool to verify the jq download, so it won't be used."
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    warn "The downloaded jq didn't match its official checksum, so it won't be used."
    rm -f "$TMP_DIR/$name"
    return 1
  fi
  chmod 755 "$TMP_DIR/$name"
  "$TMP_DIR/$name" --version >/dev/null 2>&1 || { warn "The downloaded jq doesn't run on this machine."; return 1; }
  JSON_TOOL=jq; JQ_BIN="$TMP_DIR/$name"; DOWNLOADED_JQ="$name"
  fixed "Downloaded jq $JQ_VERSION (checksum verified)"
}

ensure_json_tool() {
  pick_json_tool && return 0
  warn "Neither jq nor python3 is available; one is needed to edit settings.json."
  download_jq && return 0
  install_packages "editing settings.json" \
    brew:jq apt:jq dnf:jq yum:jq apk:jq pacman:jq zypper:jq winget:jqlang.jq scoop:jq \
    && pick_json_tool && return 0
  return 1
}

# ── settings.json: validate, repair common problems ──────────
SETTINGS_SRC=""   # file to read settings from ("" = start from {})

json_check() {  # file → 0 if valid JSON; error text in $TMP_DIR/json.err
  if [ "$JSON_TOOL" = jq ]; then
    "$JQ_BIN" empty "$1" > "$TMP_DIR/json.err" 2>&1
  else
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" > "$TMP_DIR/json.err" 2>&1
  fi
}

prepare_settings() {
  SETTINGS_SRC=""
  [ -f "$SETTINGS" ] || return 0
  if ! "$G" -q '[^[:space:]]' "$SETTINGS" 2>/dev/null; then
    fixed "settings.json was empty, so starting from a fresh one"
    return 0
  fi
  if json_check "$SETTINGS"; then SETTINGS_SRC="$SETTINGS"; return 0; fi

  warn "settings.json isn't valid JSON. Trying to repair it (the original will be backed up)..."
  local repaired="$TMP_DIR/settings.repaired.json"
  # Remove a byte-order mark, Windows line endings, whole-line // comments
  # and trailing commas: the usual hand-editing mistakes.
  if command -v perl >/dev/null 2>&1; then
    perl -0pe 's/\A\xEF\xBB\xBF//; s/\r//g; s{^[ \t]*//[^\n]*\n}{}mg; s/,(\s*[}\]])/$1/g' "$SETTINGS" > "$repaired"
  elif [ "$JSON_TOOL" = python3 ]; then
    python3 - "$SETTINGS" "$repaired" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8-sig").read().replace("\r", "")
text = re.sub(r"(?m)^[ \t]*//[^\n]*\n", "", text)
text = re.sub(r",(\s*[}\]])", r"\1", text)
open(sys.argv[2], "w", encoding="utf-8").write(text)
PY
  else
    "$S" -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e '/^[[:space:]]*\/\//d' "$SETTINGS" > "$repaired"
  fi
  if [ -s "$repaired" ] && json_check "$repaired"; then
    SETTINGS_SRC="$repaired"
    fixed "Repaired settings.json (comments, trailing commas or encoding)"
    return 0
  fi
  json_check "$SETTINGS"
  fail "$SETTINGS isn't valid JSON and couldn't be repaired automatically: $(head -1 "$TMP_DIR/json.err"). Fix that line and re-run."
}

ensure_writable() {
  local p bad=""
  for p in "$CLAUDE_DIR" "$HOOK_DIR" "$SETTINGS"; do
    if [ -e "$p" ] && [ ! -w "$p" ]; then bad="$p"; fi
  done
  [ -z "$bad" ] && return 0
  warn "$bad isn't writable by $USER_NAME (often from running Claude with sudo once)."
  if confirm "Give $CLAUDE_DIR back to $USER_NAME with sudo chown?" && get_sudo; then
    if $SUDO chown -R "$(id -u):$(id -g)" "$CLAUDE_DIR"; then
      fixed "Gave $CLAUDE_DIR back to $USER_NAME"
      return 0
    fi
  fi
  fail "Can't write to $bad. Run: sudo chown -R $USER_NAME ~/.claude   then run this installer again."
}

# ── Settings merge ───────────────────────────────────────────
# Prints the deny rules currently in settings.json, one per line.
current_deny_rules() {
  [ -n "$SETTINGS_SRC" ] || return 0
  if [ "$JSON_TOOL" = jq ]; then
    "$JQ_BIN" -r '(.permissions.deny // [])[]' "$SETTINGS_SRC"
  else
    python3 -c 'import json,sys; [print(r) for r in json.load(open(sys.argv[1], encoding="utf-8")).get("permissions",{}).get("deny",[])]' "$SETTINGS_SRC"
  fi
}

# Prints the updated settings JSON to stdout.
# $1 = install | uninstall; remaining args = deny rules to add or remove.
transform_settings() {
  local mode="$1" src="$TMP_DIR/settings.in.json"
  shift
  if [ -n "$SETTINGS_SRC" ]; then cp "$SETTINGS_SRC" "$src"; else printf '{}' > "$src"; fi

  if [ "$JSON_TOOL" = jq ]; then
    local deny_json='[]'
    if [ $# -gt 0 ]; then
      deny_json="$(printf '%s\n' "$@" | "$JQ_BIN" -R . | "$JQ_BIN" -s .)" || return 1
    fi
    "$JQ_BIN" --arg mode "$mode" --arg cmd "$HOOK_CMD" --arg matcher "$HOOK_MATCHER" --argjson deny "$deny_json" '
      def ours: tostring | contains("secret-guard.sh");
      .permissions = (.permissions // {})
      | .permissions.deny = (.permissions.deny // [])
      | .hooks = (.hooks // {})
      | .hooks.UserPromptSubmit = [(.hooks.UserPromptSubmit // [])[] | select(ours | not)]
      | .hooks.PreToolUse = [(.hooks.PreToolUse // [])[] | select(ours | not)]
      | if $mode == "install" then
          .permissions.deny += ($deny - .permissions.deny)
          | .hooks.UserPromptSubmit += [{hooks: [{type: "command", command: $cmd}]}]
          | .hooks.PreToolUse += [{matcher: $matcher, hooks: [{type: "command", command: $cmd}]}]
        else
          .permissions.deny -= $deny
        end
      | .hooks |= with_entries(select(.value != []))
      | if .hooks == {} then del(.hooks) else . end
      | if .permissions.deny == [] then del(.permissions.deny) else . end
      | if .permissions == {} then del(.permissions) else . end
    ' "$src"
  else
    python3 - "$src" "$mode" "$HOOK_CMD" "$HOOK_MATCHER" "$@" <<'PY'
import json, sys
path, mode, cmd, matcher, *deny = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
ours = lambda entry: "secret-guard.sh" in json.dumps(entry)
perms = data.setdefault("permissions", {})
rules = perms.setdefault("deny", [])
hooks = data.setdefault("hooks", {})
for event in ("UserPromptSubmit", "PreToolUse"):
    hooks[event] = [e for e in hooks.get(event, []) if not ours(e)]
if mode == "install":
    rules += [r for r in deny if r not in rules]
    hooks["UserPromptSubmit"].append({"hooks": [{"type": "command", "command": cmd}]})
    hooks["PreToolUse"].append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd}]})
else:
    perms["deny"] = [r for r in rules if r not in deny]
for event in [e for e, v in hooks.items() if v == []]:
    del hooks[event]
if not hooks:
    del data["hooks"]
if not perms.get("deny"):
    perms.pop("deny", None)
if not perms:
    del data["permissions"]
print(json.dumps(data, indent=2))
PY
  fi
}

update_settings() {  # install | uninstall, then the deny rules to add or remove
  local out="$TMP_DIR/settings.out.json" backup
  transform_settings "$@" > "$out" || fail "Couldn't update $SETTINGS."
  json_check "$out" || fail "Settings update produced invalid JSON; $SETTINGS left unchanged."
  if [ -f "$SETTINGS" ]; then
    backup="$SETTINGS.bak-secret-guard-$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$backup" || fail "Couldn't back up $SETTINGS"
    ok "Backed up settings to $backup"
  fi
  # Write in place (not mv) so symlinked settings files keep working.
  cat "$out" > "$SETTINGS" || fail "Couldn't write $SETTINGS"
}

# ── Embedded files ───────────────────────────────────────────
write_guard() {
  cat > "$1" <<'__SECRET_GUARD_SH_EOF__'
@@SECRET_GUARD_SH@@
__SECRET_GUARD_SH_EOF__
}

write_tests() {
  cat > "$1" <<'__TEST_SECRET_GUARD_SH_EOF__'
@@TEST_SH@@
__TEST_SECRET_GUARD_SH_EOF__
}

# ── Self-test with diagnosis and repair ──────────────────────
# Runs the test suite against the guard. $1 = folder of helper tools to put
# first on the guard's PATH ("" = none, i.e. this machine's defaults).
run_selftest() {
  local bin="${1:-$TMP_DIR/no-helper-tools}" line
  SECRET_GUARD_BIN="$bin" bash "$TMP_DIR/test-secret-guard.sh" "$TMP_DIR/secret-guard.sh" \
    > "$TMP_DIR/selftest.out" 2>&1
  line="$("$G" -E '^Result: ' "$TMP_DIR/selftest.out" | tail -1)"
  TESTS_PASSED="$(printf '%s' "$line" | "$S" -nE 's/^Result: ([0-9]+) passed.*/\1/p')"
  TESTS_FAILED="$(printf '%s' "$line" | "$S" -nE 's/.* ([0-9]+) failed.*/\1/p')"
  TESTS_PASSED="${TESTS_PASSED:-0}"
  TESTS_FAILED="${TESTS_FAILED:-1}"
  [ "$TESTS_FAILED" = 0 ] && [ "$TESTS_PASSED" -gt 0 ]
}

show_failures() {
  "$G" -E '^FAIL' "$TMP_DIR/selftest.out" | head -8 | while IFS= read -r l; do say "      $l"; done
  if ! "$G" -qE '^Result: ' "$TMP_DIR/selftest.out"; then
    say "      (the test suite didn't finish; its last output:)"
    tail -3 "$TMP_DIR/selftest.out" | while IFS= read -r l; do say "      $l"; done
  fi
}

make_helper_tools() {  # dir, grep path, sed path
  mkdir -p "$1"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$2" > "$1/grep"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$3" > "$1/sed"
  chmod 755 "$1/grep" "$1/sed"
}

candidates() {  # grep | sed → existing, de-duplicated full paths
  local list p seen=" "
  if [ "$1" = grep ]; then
    list="grep /usr/bin/grep /bin/grep ggrep /opt/homebrew/bin/ggrep /usr/local/bin/ggrep /opt/homebrew/opt/grep/libexec/gnubin/grep /usr/local/opt/grep/libexec/gnubin/grep"
  else
    list="sed /usr/bin/sed /bin/sed gsed /opt/homebrew/bin/gsed /usr/local/bin/gsed /opt/homebrew/opt/gnu-sed/libexec/gnubin/sed /usr/local/opt/gnu-sed/libexec/gnubin/sed"
  fi
  for p in $list; do
    p="$(command -v "$p" 2>/dev/null)" || continue
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "
    echo "$p"
  done
}

# Tries every grep/sed pair on this machine until the tests pass.
try_other_tools() {
  local g s default_g default_s
  default_g="$(command -v grep 2>/dev/null)"
  default_s="$(command -v sed 2>/dev/null)"
  for g in $(candidates grep); do
    for s in $(candidates sed); do
      [ "$g" = "$default_g" ] && [ "$s" = "$default_s" ] && continue
      make_helper_tools "$TMP_DIR/helper-tools" "$g" "$s"
      if run_selftest "$TMP_DIR/helper-tools"; then
        SHIM_GREP="$g"; SHIM_SED="$s"
        return 0
      fi
    done
  done
  return 1
}

selftest_and_heal() {
  write_guard "$TMP_DIR/secret-guard.sh"
  write_tests "$TMP_DIR/test-secret-guard.sh"
  # Never let Windows line endings sneak into the files we install
  tr -d '\r' < "$TMP_DIR/secret-guard.sh" > "$TMP_DIR/g.tmp" && mv "$TMP_DIR/g.tmp" "$TMP_DIR/secret-guard.sh"
  tr -d '\r' < "$TMP_DIR/test-secret-guard.sh" > "$TMP_DIR/t.tmp" && mv "$TMP_DIR/t.tmp" "$TMP_DIR/test-secret-guard.sh"

  if run_selftest ""; then
    ok "$TESTS_PASSED tests passed"
    return 0
  fi

  warn "$TESTS_FAILED test(s) failed with this machine's default tools:"
  show_failures
  say "    Diagnosing and fixing..."

  # Fix 1: another grep/sed already on this machine
  if try_other_tools; then
    fixed "Default grep/sed misbehave here, so the guard uses $SHIM_GREP and $SHIM_SED"
    ok "All $TESTS_PASSED tests pass now"
    return 0
  fi

  # Fix 2: install GNU grep and sed, then try again
  if install_packages "a working grep and sed" \
       "brew:grep gnu-sed" "apt:grep sed" "dnf:grep sed" "yum:grep sed" "apk:grep sed" \
       "pacman:grep sed" "zypper:grep sed" && try_other_tools; then
    fixed "The guard will use $SHIM_GREP and $SHIM_SED"
    ok "All $TESTS_PASSED tests pass now"
    return 0
  fi

  # Diagnose: does a clean shell environment pass?
  run_selftest ""   # restore the original failure details
  if env -i HOME="$HOME" PATH="$PATH" bash "$TMP_DIR/test-secret-guard.sh" "$TMP_DIR/secret-guard.sh" 2>&1 \
       | "$G" -q '^Result: [0-9]* passed, 0 failed'; then
    local v suspects=""
    for v in BASH_ENV ENV SHELLOPTS BASHOPTS GREP_OPTIONS POSIXLY_CORRECT LD_PRELOAD DYLD_INSERT_LIBRARIES; do
      printenv "$v" >/dev/null 2>&1 && suspects="$suspects $v"   # exported ones only
    done
    fail "Tests pass in a clean shell but not in yours, so a shell setting is interfering${suspects:+ (check:$suspects)}. Remove it from your shell profile and re-run. Nothing was changed."
  fi
  show_failures
  fail "Self-test still fails after trying every fix ($TESTS_PASSED passed, $TESTS_FAILED failed). Nothing was changed. Send the lines above to whoever gave you this script."
}

# ── Run ──────────────────────────────────────────────────────
say "NULogic secret-guard $MODE (v$VERSION)"
say "User: $USER_NAME   Machine: $HOST_NAME   OS: $OS $OS_VERSION ($ARCH)"
if report_enabled; then
  say "This sends a short $MODE report (username, machine name, OS, result) to"
  say "$REPORT_URL. Run with --no-report to skip it."
fi

step "Checking requirements"
if [ -z "$G" ] || [ -z "$S" ]; then
  warn "No working grep or sed found."
  install_packages "basic text tools" "brew:grep gnu-sed" "apt:grep sed" "dnf:grep sed" "yum:grep sed" \
    "apk:grep sed" "pacman:grep sed" "zypper:grep sed" || { S="${S:-sed}"; G="${G:-grep}"; fail "grep and sed are required. Install them and re-run."; }
  G="$(first_working_grep)" || { G=grep; fail "grep still doesn't work after installing it."; }
  S="$(first_working_sed)" || { S=sed; fail "sed still doesn't work after installing it."; }
fi
ok "Text tools: $G, $S"
ensure_json_tool || fail "Couldn't set up jq or python3 to edit settings.json. Install either one and re-run."
if [ "$JSON_TOOL" = jq ]; then ok "Using jq${DOWNLOADED_JQ:+ (downloaded)} to edit settings"; else ok "Using python3 to edit settings"; fi
if [ -n "$CLAUDE_VERSION" ]; then ok "Claude Code found: $CLAUDE_VERSION"
else warn "Claude Code CLI not found on PATH. Installing anyway; it takes effect once Claude Code is installed."
fi
for managed in "/Library/Application Support/ClaudeCode/managed-settings.json" \
               "/etc/claude-code/managed-settings.json"; do
  if [ -f "$managed" ] && "$G" -q '"allowManagedHooksOnly"[[:space:]]*:[[:space:]]*true' "$managed"; then
    warn "$managed only allows managed hooks, so a user-level hook won't run."
  fi
done
ensure_writable
prepare_settings

if [ "$MODE" = uninstall ]; then
  step "Removing secret-guard"
  if [ -f "$SETTINGS" ]; then
    REMOVE_RULES=()
    if [ -f "$RULES_RECORD" ]; then
      while IFS= read -r rule; do
        [ -n "$rule" ] && REMOVE_RULES+=("$rule")
      done < "$RULES_RECORD"
    else
      REMOVE_RULES=("${DENY_RULES[@]}")
    fi
    # ${arr[@]+...} keeps bash 3.2 (macOS) happy when the array is empty under set -u
    update_settings uninstall ${REMOVE_RULES[@]+"${REMOVE_RULES[@]}"}
    ok "Removed secret-guard hooks and its deny rules from $SETTINGS"
  fi
  rm -f "$HOOK_PATH" "$RULES_RECORD"
  rm -rf "$BIN_DIR"
  ok "Removed $HOOK_PATH and its helper tools"
  report success "uninstalled"
  say ""
  say "Done. Restart Claude Code for this to take effect."
  exit 0
fi

step "Testing the guard on this machine"
selftest_and_heal

step "Installing"
mkdir -p "$HOOK_DIR" || fail "Couldn't create $HOOK_DIR"
{ cp "$TMP_DIR/secret-guard.sh" "$HOOK_PATH" && chmod 755 "$HOOK_PATH"; } || fail "Couldn't write $HOOK_PATH"
ok "Hook script at $HOOK_PATH"
if [ -n "$SHIM_GREP" ]; then
  make_helper_tools "$BIN_DIR" "$SHIM_GREP" "$SHIM_SED"
  ok "Helper tools at $BIN_DIR"
else
  rm -f "$BIN_DIR/grep" "$BIN_DIR/sed"
fi
if [ -n "$DOWNLOADED_JQ" ]; then
  mkdir -p "$BIN_DIR" && cp "$JQ_BIN" "$BIN_DIR/$DOWNLOADED_JQ" && chmod 755 "$BIN_DIR/$DOWNLOADED_JQ" \
    && ok "Kept the downloaded jq in $BIN_DIR (reused by --uninstall)"
fi
rmdir "$BIN_DIR" 2>/dev/null

# On first install, remember which deny rules were new so uninstall removes only those.
if [ ! -f "$RULES_RECORD" ]; then
  EXISTING_RULES="$(current_deny_rules)"
  : > "$TMP_DIR/added-rules"
  for rule in "${DENY_RULES[@]}"; do
    printf '%s\n' "$EXISTING_RULES" | "$G" -qxF -- "$rule" || printf '%s\n' "$rule" >> "$TMP_DIR/added-rules"
  done
fi
update_settings install "${DENY_RULES[@]}"
[ -f "$RULES_RECORD" ] || cp "$TMP_DIR/added-rules" "$RULES_RECORD"
ok "Hooks and deny rules added to $SETTINGS"

# Final check: run the installed hook exactly as Claude Code will.
SAMPLE_KEY="AKIA""IOSFODNN7EXAMPLE"   # AWS's public example key, split so it isn't a literal
printf '{"hook_event_name":"UserPromptSubmit","prompt":"my key is %s"}' "$SAMPLE_KEY" \
  | SECRET_GUARD_LOG="$TMP_DIR/final.log" bash "$HOOK_PATH" >/dev/null 2>&1
blocked=$?
printf '{"hook_event_name":"UserPromptSubmit","prompt":"hello"}' \
  | SECRET_GUARD_LOG="$TMP_DIR/final.log" bash "$HOOK_PATH" >/dev/null 2>&1
allowed=$?
if [ "$blocked" = 2 ] && [ "$allowed" = 0 ]; then
  ok "Installed hook checked: blocks a key, lets normal messages through"
else
  warn "The installed hook didn't behave as expected (key: exit $blocked, normal: exit $allowed)."
  warn "Run: bash install-secret-guard.sh --uninstall   and send this output to whoever gave you the script."
fi

report success "installed"

say ""
if [ -n "$FIXES" ]; then
  say "Fixed along the way:"
  printf '%s\n' "$FIXES" | tr ';' '\n' | while IFS= read -r l; do say "  • ${l# }"; done
  say ""
fi
say "Done. Next steps:"
say "  1. Restart Claude Code, then run /hooks to see the two secret-guard hooks."
say "  2. Try it: type  my key is ${SAMPLE_KEY}  (AWS's public example key)."
say "     It should be blocked before it reaches Claude."
say "  3. Blocks are logged (rule name only, never the key) to ~/.claude/secret-guard.log"
say "To remove it: bash install-secret-guard.sh --uninstall"
