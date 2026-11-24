# "I pasted a key" runbook

Use this when a real key, password or token was pasted into Claude (or any AI tool, chat, ticket or public place). It applies even if you deleted the message straight away. **Speed matters more than anything else, and reporting quickly is always the right call.**

## Do this now (first 15 minutes)

1. **Revoke or rotate the key.** Treat it as leaked. Generate a new key in the provider's console (AWS IAM, GitHub, Stripe, the database, and so on) and disable the old one. Deleting the chat doesn't undo the leak; rotating does.
2. **Tell security.** Post in **[#security channel]** or contact **[security contact]** with:
   - which key it was (its name or ID, **never the value**)
   - where it went (claude.ai, Claude Code, Slack, a ticket...)
   - roughly when
   - whether it's rotated yet
3. **Update everything that uses it.** Put the new key into the vault, CI secrets or deployment config, then redeploy if needed so nothing breaks.

## Then (same day)

4. **Check the key's usage logs** from the time of the paste until it was revoked: CloudTrail for AWS, the audit log for GitHub, the dashboard for Stripe or Twilio, connection logs for databases. Report anything you don't recognise to security.
5. **Delete the message or chat** where it was pasted. That's good hygiene, but it doesn't replace rotation.
6. **Close the loop:** security confirms the key is rotated, nothing suspicious was found, and notes the incident.

## For security / IT

| Key type | Revoke it in | Check usage in |
|---|---|---|
| AWS access key | IAM → Users → Security credentials | CloudTrail |
| GitHub token | Settings → Developer settings → Tokens (or the org's audit log) | Org audit log |
| Stripe live key | Dashboard → Developers → API keys → Roll key | Dashboard logs |
| Slack token | The app's settings → Revoke tokens | Workspace access logs |
| Database password | Change the user's password, then rotate the app secret | DB connection / audit logs |
| Private key / certificate | Re-issue and revoke the old certificate; replace SSH keys | Server auth logs |

## Making leaks less damaging

- Keep production keys in a vault (AWS Secrets Manager, HashiCorp Vault) so few people ever handle them directly.
- Prefer short-lived, narrowly scoped credentials.
- Rotate on a schedule, so any key's useful life is short anyway.

The secret guard blocks most accidental pastes in Claude Code, but no filter catches everything, and it doesn't cover the claude.ai website or mobile apps. This runbook is the backstop.
