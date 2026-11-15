# Log: imsg-companion

Append only. Newest at the bottom. Public: no personal data.

## 2026-11-15 08:55 ET — Repo created
- Alex approved the standalone-agent design (2026-11-15 08:13 ET) and its plan for inline execution (08:32 ET). History before this lives in the fork's `.claude/LOG.md` (`Goldalex98/msgblast-imessage`).
- Plan Task 1 passed on the MacBook (Xcode 27.2): `openclaw/imsg` pinned `exact: "0.21.0"` resolves and builds with no `unsafeFlags` refusal; `IMsgCore` read a synthetic fixture (which needed only `message.service` added); a hardened-runtime probe signed with the Apple Development identity and ran. `Package.resolved` here is the one from that proof.
- Task 2: this scaffold, CI on the `xcode-27` runner, and the contract's 2026-11-15 additions (per-message service, unsent re-posts, `sent_service`, `control.paused`, `POST /imsg/status`) for HomeChat's session to build against.
