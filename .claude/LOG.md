# Log: imsg-companion

Append only. Newest at the bottom. Public: no personal data.

## 2026-11-15 08:55 ET — Repo created
- Alex approved the standalone-agent design (2026-11-15 08:13 ET) and its plan for inline execution (08:32 ET). History before this lives in the fork's `.claude/LOG.md` (`Goldalex98/msgblast-imessage`).
- Plan Task 1 passed on the MacBook (Xcode 27.2): `openclaw/imsg` pinned `exact: "0.21.0"` resolves and builds with no `unsafeFlags` refusal; `IMsgCore` read a synthetic fixture (which needed only `message.service` added); a hardened-runtime probe signed with the Apple Development identity and ran. `Package.resolved` here is the one from that proof.
- Task 2: this scaffold, CI on the `xcode-27` runner, and the contract's 2026-11-15 additions (per-message service, unsent re-posts, `sent_service`, `control.paused`, `POST /imsg/status`) for HomeChat's session to build against.

## 2026-11-15 08:50 ET — Tasks 2–4
- PR #1 (scaffold) merged `69f9fb1`; its PR and `main` runs on GitHub's `xcode-27` runner were green, which answers design §9's "builds under Xcode 27" for CI.
- PR #2 (safety core) merged `7551e40`. Lifted unchanged except `HandleNormalizer` (pinned to the fork's fingerprint for a fixed input, `0e6c…a68b`). Then the plan's changes: tunables, no 9003, a no-send preflight source, the new wire fields. Rulings: `READY` parses as `.ready`, and during a dispatch it decides `ambiguous`; `CompanionOutgoingRow` moved into the send models. Send-safety review: pass. Its notes: the forbidden-API guard doesn't list `NSAppleScript`/`Process`; the preflight source leaves an unused flag.
- PR #3 (`ChatQueries`) open. The required columns now include `error` and `is_sent` at open (the fork checked them only on the send path). A `chat.db` without them fails at start instead of at the first send.
