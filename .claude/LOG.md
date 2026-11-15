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

## 2026-11-15 08:59 ET — Tasks 4–5
- PR #3 (`ChatQueries`) merged `db5acc1`; `main` CI green.
- PR #4 merged `151891d`: `CompanionService` pages with `IMsgCore`'s `messagesAfterPage` (read-only `MessageStore`) and takes threads, system-row facts and the from-me set from `ChatQueries`. The cursor follows `nextRowID`, held below a chat-less row under 10 s old. The code skip applies only in threads with no from-me row. Rulings: system and unreadable rows follow the fork's rules; the reset status is the machine string `database_replaced`. Not exercised by tests: `IMsgCore`'s URL-preview folding (a fake pager stands in) and any real `chat.db`. Send-safety review: no findings; three notes kept as deferred minors.

## 2026-11-15 09:02 ET — Task 6
- PR #5 merged `cd4538e` (PR CI green). `UnsendRelay` re-posts `.unsent` watcher events with the saved cursor, so the cursor never moves. `UplinkSerializer` carries every batch, so posts go one at a time; its test fails with the queue removed. Rulings: an unsend past the saved cursor is left to the reading loop; a 4xx rejection drops the re-post; re-posts carry Contacts names. Not run: a real `MessageWatcher`, and HomeChat's update path.

## 2026-11-15 09:11 ET — Task 7
- PR #6 merged `0068d31` (PR CI green). The `chat.service_name` check is gone, and `sent_service` comes from the read-back row. The poll runs while sends are off or paused, but a send fetched then is ignored: no ledger record, no result. Removing that gate fails 4 tests. Baseline: the global max ROWID. Read-back pages to the end across twin chats.
- Found while testing: without `message.associated_message_guid`, IMsgCore returns an empty guid for every row. The fixture now has the column, and a reader test asserts the guid. Real `chat.db` has it.
- Deferred minors from the safety review: twins ignore chat style; one more off/paused check before the ledger write would narrow a window; link texts may read back as `no_readback` (ambiguous); preflight isn't serialized with a dispatch. No real send has run: the AppleScript against Messages and the SMS/RCS routes are unproven.

## 2026-11-15 09:16 ET — Task 8
- PR #7 merged `b58ab85` (PR CI green). `AgentStatus` carries exactly the contract's keys, with nulls always sent. `StatusReporter` posts every 15 min and on a change. `PauseState` holds HomeChat's pause in memory and can only pause. `ForkGuard` blocks uplink while the fork app runs. The permission readouts ask for nothing. The Contacts resolver is lifted from the fork. Task 9 must apply every poll's control, gate all three uplink paths with `ForkGuard`, and set `last_error` only from fixed codes.

## 2026-11-15 09:23 ET — Task 9
- PR #8 merged `3926922` (PR CI green). `run` wires the reader, the unsend relay, the executor and the status reporter, all behind `ForkGuard`. SIGTERM reads as a pause for the executor, and the agent waits for the current cycle before exiting. Config writes from the agent and the commands share an `flock`. `update` waits for the updater (Task 11) instead of shipping as a placeholder. Review's Important finding: exit can take a long-poll plus a dispatch, so the launchd plist sets `ExitTimeOut` 120 (Task 10). Not run yet: the agent itself.
