@AGENTS.md

## Claude Code setup
- No project MCP servers.
- `.claude/settings.json` pre-allows only the gate commands and denies reading `.env*`, `*.local.json`, `.local/`, and the Messages and Contacts stores under `~/Library`. Read denies don't cover Bash; the rules above do.
- Claude Code also uses its user-level evidence-verifier, implementer and global git-guard hook.
