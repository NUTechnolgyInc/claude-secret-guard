# Claude Secret Guard

A Claude Code hook that stops API keys, passwords and secret files from reaching Claude by accident. One installer sets it up per user in a few seconds, and one command removes it.

## Install

Download the installer and its checksum from the [latest release](https://github.com/NUTechnolgyInc/claude-secret-guard/releases/latest), check it, and run it:

```bash
curl -fsSLO https://github.com/NUTechnolgyInc/claude-secret-guard/releases/latest/download/install-secret-guard.sh
curl -fsSLO https://github.com/NUTechnolgyInc/claude-secret-guard/releases/latest/download/install-secret-guard.sh.sha256
shasum -a 256 -c install-secret-guard.sh.sha256
bash install-secret-guard.sh
```

Then restart Claude Code and run `/hooks` to see the two secret-guard hooks.

This per-user install is for testing and pilots: it lives in `~/.claude`, so the user can remove it. For company-wide enforcement, use the managed install below.

## Enforced install (IT / admin)

```bash
sudo bash install-secret-guard.sh --managed
```

This installs for every user on the machine (macOS, Linux, WSL), and users can't remove or override it without admin rights:

| What | Where |
|---|---|
| Hook script, owned by root | `/opt/nulogic/secret-guard.sh` |
| Policy file Claude Code always obeys | macOS: `/Library/Application Support/ClaudeCode/managed-settings.json`<br>Linux / WSL: `/etc/claude-code/managed-settings.json` |

The policy (same as [`managed-settings.json`](managed-settings.json)) registers the hooks and deny rules and enforces:

- **Fails closed:** if the script is missing or crashes, every prompt is blocked with "NULogic secret-guard is missing. Contact IT." On Claude Code 2.1.295+, `onFailure: "block"` also blocks on a timeout.
- **`allowManagedHooksOnly`:** users can't add their own hooks to work around it.
- **`disableBypassPermissionsMode`:** `--dangerously-skip-permissions` is rejected.
- **Ignores the user's PATH:** the admin copy of the guard uses only system tools, so a fake `grep` can't switch it off.

If the machine already has a managed policy, the installer merges into it, and `--managed --uninstall` removes only what it added. Run `/status` in Claude Code to confirm: the policy shows under *Setting sources* as `(file)`.

| Option | What it does |
|---|---|
| `--uninstall` | Removes the hooks, the hook script, and only the rules and settings the installer added |
| `--managed` | System-wide, admin-enforced install (needs sudo) |
| `--strict-permissions` | With `--managed`: users' own allow/deny rules are ignored; only the policy's rules apply |
| `--require-version` | With `--managed`: Claude Code older than 2.1.295 refuses to start, so a hook timeout also blocks |
| `--no-report` | Skips the one-time install report |
| `--yes` | Approves tool installs (package manager, sudo) without asking |

**Limits:** anyone with admin rights on their laptop can still change the policy, so keep developers off local admin, or re-run the installer from your device management to repair drift. If your org also sets managed settings in the Claude admin console, those replace this file unless the console policy sets `"managedSourcesBehavior": "merge"`.

Works on macOS, Linux, and Windows via Git Bash or WSL. Only `bash` is required: the installer downloads `jq` (checksum-verified) or installs GNU `grep`/`sed` if they're missing, repairs common `settings.json` mistakes, and re-runs its self-test after each fix. If it can't fix something, it explains why and changes nothing.

## What it blocks

- **In your messages:** AWS, GitHub, Slack, Google and Stripe live keys; `sk-…` style keys; private key blocks; JWTs; database URLs with passwords; `NAME_PASSWORD=…`-style assignments with long values.
- **For Claude:** reading or running commands on `.env` files, `.pem`, `.key`, `.p12`, `.pfx`, SSH keys, `credentials.json`, `~/.aws/credentials` and `secrets/` folders; writing keys into files; and question forms, whose answers would skip the check.
- **Still allowed:** `.env.example` / `.sample` / `.template`, code like `process.env.X`, placeholders like `[REDACTED]`, and normal questions about passwords.

Blocks are logged locally to `~/.claude/secret-guard.log` with the rule name only, never the value.

Coverage: terminal, IDE extensions, and the Claude desktop app's Code tab. Claude Code on the web needs [server-managed settings](https://code.claude.com/docs/en/server-managed-settings.md) instead.

## Install reports

The installer sends one report per install or uninstall: event, result, username, machine name, OS, Claude Code version, installer version, test counts and time. Never keys, files, settings or prompts. Reports go to the API in [`api-server/`](api-server/) (a Vercel function storing to MongoDB).

List them with an admin token (kept in `~/.config/secret-guard-api/admin-token`, never in this repo):

```bash
bash fetch-reports.sh              # latest reports
bash fetch-reports.sh --machines   # current state per user + machine
bash fetch-reports.sh status=failed
```

## Repository layout

| Path | Purpose |
|---|---|
| `secret-guard.sh` | The hook itself |
| `test-secret-guard.sh` | Test suite (all keys in it are fake or public examples) |
| `installer-template.sh` | Installer source; the guard and tests are embedded at build time |
| `build-installer.sh` | Builds `install-secret-guard.sh` and its `.sha256` |
| `fetch-reports.sh` | Lists install reports from the API |
| `api-server/` | Reporting API (Vercel + MongoDB) |
| `managed-settings.json` | The policy `--managed` writes, for reference or other deployment tools |
| `settings.local-test.json` | The same hooks for a single user's `~/.claude/settings.json` |
| `docs/secret-guard-guide.html` | Guide for colleagues |
| `docs/announcement.md` | Rollout announcement for Slack or email |
| `docs/leaked-key-runbook.md` | What to do when a key does get pasted somewhere |

## Releasing a new version

```bash
bash test-secret-guard.sh ./secret-guard.sh
bash build-installer.sh 1.4.1
gh release create v1.4.1 install-secret-guard.sh install-secret-guard.sh.sha256 --title v1.4.1 --notes "What changed"
```

The build reads the report token from `SECRET_GUARD_REPORT_TOKEN` or `~/.config/secret-guard-api/ingest-token`. It's an ingest-only token (it can add install records, nothing else) and is never committed; the built installer, which contains it, is only published as a release asset.
