# Announcement: Claude Code secret guard

Ready to post in Slack or send by email. Replace the bracketed parts before sending.

---

**Subject: Claude Code now blocks API keys and passwords 🔒**

Hi all,

Starting **[date]**, Claude Code on company laptops will block messages that contain API keys, passwords or other credentials, before they reach Claude. It also stops Claude from opening secret files such as `.env`, `.pem` and SSH keys.

**Why:** keys pasted into AI tools can end up stored outside our control. Even one leaked production key can be costly, so this catches the accidental ones.

**What you'll notice**

- If a message contains a key, you'll see a 🔒 *NULogic secret-guard blocked this message* warning, and the message is **not sent**. Replace the value with a placeholder such as `[REDACTED]` and send it again.
- Claude can't read `.env` or key files. `.env.example`, `.env.sample` and `.env.template` still work.
- Claude asks questions in plain chat instead of clickable forms. Answers typed into forms would skip the check.

**What it doesn't do**

- It doesn't read or upload your code, and it never records the key itself. It runs entirely on your laptop. Each block is logged locally with the rule name only.
- It doesn't cover the claude.ai website or the Claude mobile app yet, so please keep keys out of those too.

**You don't need to do anything.** IT is installing it on every laptop. If it blocks something that isn't a secret, tell us in **[#channel / contact]** with the rule name from the warning. Never include the value itself.

**If a key ever does get pasted anywhere it shouldn't,** follow the "I pasted a key" runbook: **[link]**. The most important step is rotating the key straight away, and nobody gets in trouble for reporting it quickly.

Thanks,
**[Name, team]**
