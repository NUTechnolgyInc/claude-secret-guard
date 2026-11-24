#!/usr/bin/env bash
# Runs fake (synthetic) inputs through secret-guard.sh and checks the result.
# Usage: bash test-secret-guard.sh [path/to/secret-guard.sh]
# All keys below are fake/example values — none are real credentials.

GUARD="${1:-$HOME/.claude/hooks/secret-guard.sh}"
# Don't pollute the real log
export SECRET_GUARD_LOG="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/secret-guard-test.$$.log")"
pass=0; fail=0

check() {  # name, expected_exit, json
  printf '%s' "$3" | bash "$GUARD" >/dev/null 2>&1
  local code=$?
  if [ "$code" = "$2" ]; then echo "PASS  $1"; pass=$((pass + 1))
  else echo "FAIL  $1 (expected $2, got $code)"; fail=$((fail + 1)); fi
}

P='{"hook_event_name":"UserPromptSubmit","prompt":'
T='{"hook_event_name":"PreToolUse","tool_name":'

echo "── Prompts that should PASS"
check "normal question"        0 "$P\"Fix the null pointer in UserService.java\"}"
check "placeholder value"      0 "$P\"Set API_KEY=[REDACTED] in config\"}"
check "talks about passwords"  0 "$P\"How do I hash a password with bcrypt?\"}"
check "accents and emoji"      0 "$P\"Café résumé naïve ☕ 🔒 — fix the build\"}"

echo "── Prompts that should BLOCK"
check "AWS key"                2 "$P\"my key is AKIAIOSFODNN7EXAMPLE\"}"
check "GitHub token"           2 "$P\"use ghp_abcdefghijklmnopqrstuvwxyz0123456789\"}"
check "Anthropic-style key"    2 "$P\"sk-ant-api03-FAKEFAKEFAKEFAKEFAKEFAKE\"}"
check "private key"            2 "$P\"-----BEGIN RSA PRIVATE KEY-----\\nMIIfake\"}"
check "JWT"                    2 "$P\"token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0dXNlciJ9.ZmFrZXNpZ25hdHVyZQ\"}"
check "DB URL with password"   2 "$P\"postgres://app:Sup3rS3cretPass@db.internal:5432/app\"}"
check "DB_PASSWORD assignment" 2 "$P\"DB_PASSWORD=Xk9mP2vL8qR4tW7zQ1\"}"

echo "── Tool calls that should PASS"
check "Read source file"       0 "$T\"Read\",\"tool_input\":{\"file_path\":\"/repo/src/app.ts\"}}"
check "Read .env.example"      0 "$T\"Read\",\"tool_input\":{\"file_path\":\"/repo/.env.example\"}}"
check "Bash npm test"          0 "$T\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"
check "Bash process.env code"  0 "$T\"Bash\",\"tool_input\":{\"command\":\"node -e 'console.log(process.env.HOME)'\"}}"
check "Bash import.meta.env"   0 "$T\"Bash\",\"tool_input\":{\"command\":\"grep -r import.meta.env.VITE_URL src\"}}"
check "Grep for process.env"   0 "$T\"Grep\",\"tool_input\":{\"pattern\":\"process.env.DATABASE\",\"path\":\"/repo/src\"}}"

echo "── Tool calls that should BLOCK"
check "Read .env"              2 "$T\"Read\",\"tool_input\":{\"file_path\":\"/repo/.env\"}}"
check "Read .env.production"   2 "$T\"Read\",\"tool_input\":{\"file_path\":\"/repo/.env.production\"}}"
check "Bash cat .env"          2 "$T\"Bash\",\"tool_input\":{\"command\":\"cat .env\"}}"
check "Read AWS credentials"   2 "$T\"Read\",\"tool_input\":{\"file_path\":\"/home/dev/.aws/credentials\"}}"
check "Read .pem"              2 "$T\"Read\",\"tool_input\":{\"file_path\":\"/repo/certs/server.pem\"}}"
check "Bash cat prod.env"      2 "$T\"Bash\",\"tool_input\":{\"command\":\"cat config/prod.env\"}}"
check ".env next to process.env" 2 "$T\"Bash\",\"tool_input\":{\"command\":\"echo process.env.X && cat .env\"}}"
check "Question form"          2 "$T\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Which DB?\"}]}}"
check "Write key into file"    2 "$T\"Write\",\"tool_input\":{\"file_path\":\"/repo/cfg.js\",\"content\":\"key='AKIAIOSFODNN7EXAMPLE'\"}}"

echo
echo "Result: $pass passed, $fail failed"
rm -f "$SECRET_GUARD_LOG"
[ "$fail" -eq 0 ]
