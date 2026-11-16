# Status: imsg-companion

**Updated:** 2026-11-15 19:05 ET
**At:** Stage U is under way: U1–U5 passed (U5's never-written-thread code case not run). The agent runs `2c8de3f` (installed by hand at 15:16 ET), with Contacts and Full Disk Access granted, not paused, sends off, and real texts uplinking. Nothing has been sent.
**Next:** U6 (unsend), U7 (WhatsApp pause/resume), U9 (unsaved number), then U8's remaining cases on the next merged PR. Each HomeChat-side check is asked of HomeChat's own session, with Alex relaying.
**Phase:** Acceptance: Stage U, then (after the fork's token is revoked) Stage S.
**Milestones:** Dependency proof ✓ · Scaffold ✓ · Safety core ✓ · Reading ✓ · Sending ✓ (built, never run against Messages) · Status and control ✓ · Packaging ✓ · Updates ✓ (rollback seen live; install unproven until the next PR) · Runbooks ✓ · Cutover ✓ · Acceptance (Stage U: U1–U5 ✓)

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## RUNNING NOW
- CI (`ci.yml`) on PRs and pushes to `main`: tests, the ad hoc app build and the Dependabot diff check. The `automerge` job runs only on Dependabot's PRs.
- Dependabot (swift, daily, 3-day cooldown). No bump PR yet: the automerge live check (Task 12 Step 4) is pending.
- `ImsgCompanion.app` in `~/Applications` on the MacBook, under launchd, running `2c8de3f` since 15:16 ET (`scripts/install.sh`, Alex approved). Full Disk Access and Contacts granted, Automation not yet asked. Token in the Keychain, not paused, sends off. The updater job is loaded and has not run since the reinstall (`runs = 0`). Its first scheduled run, 2026-11-16 03:30, should install `main` `b59f35e` with the fixed health check (U8's install case).
- The fork app: quit, Login Item off, still installed and paused as the fallback (rollback in `cutover.md`).

## QUEUED
- Stage U: U6, U7, U9, then U8 (install, no-update, paused, health-fail rollback, HomeChat unreachable). Then Stage S (`stage-s.md`).
- Before Stage S: revoke the fork's token in HomeChat (Alex says when; Claude runs it). Until then HomeChat refuses every send because two Macs are linked.

## BLOCKED
- None.

## AWAITING Alex
- Stage U: his steps per `stage-u.md`.
- The go-ahead to revoke the fork's token before Stage S.

## DONE
- 2026-11-15 19:04 ET: U5 passed. Catch-up after a `bootout`: 2 rows stored once each. Offline retry: 3 network failures in the OS log, then delivered on reconnect (`last_error` in the status not observed: no snapshot fell inside the window). SSN scrub: 1 marker, 0 copies of the digits. Code text in a thread Alex writes in: stored with its text. The never-written-thread code case was not run (no such sender), so unit tests are its only cover.
- 2026-11-15 17:11 ET: PR #18 merged (`b59f35e`): U1–U4 results and runbook fixes. PR CI green; `main` push CI 43767886480 green.
- 2026-11-15 17:06 ET: U4 passed on HomeChat's stored state. A flag opened on the test question (HomeChat's session ran one flagger pass by hand), and it closed with `replied` the same second Alex's reply was stored. Seeing it on the phone is not verified: the flag was still in HomeChat's 3-hour hold.
- 2026-11-15 16:53 ET: U2 and U3 passed. Every row past the copied cursor is stored once, with no gap at cutover and no duplicate guid. A test text was uplinked and stored within about 1 s of the agent reading it.
- 2026-11-15 15:23 ET: Contacts granted. The prompt appeared from the `2c8de3f` build, Alex allowed it, and the agent reads `granted` after a restart.
- 2026-11-15 15:16 ET: PR #17 merged (`2c8de3f`, the health-mark fix) and installed by hand. Fable's review proved both causes, and showed that kickstarting the old updater would have rolled the fix back.
- 2026-11-15 15:01 ET: U8 kickstart of `f1281f0`: built, signed, swapped and healthy (Full Disk Access kept, Contacts entitlement present, no Keychain prompt), but rolled back. The health mark stores whole seconds, and the updater compared it with a sub-second start time. The rollback itself worked under launchd. The fix is on branch `health-mark-seconds`.
- 2026-11-15 14:52 ET: PR #16 merged (`f1281f0`): the Contacts entitlement. Hardened runtime refused Contacts with no prompt without it.
- 2026-11-15 14:41 ET: U1 passed: started at login, restarted by launchd after a SIGKILL, Full Disk Access listed (Alex) and `granted`.
- 2026-11-15 14:30 ET: PR #15 merged (`f55a9fb`): cutover status.
- 2026-11-15 14:24 ET: cutover steps 1–10 passed. HomeChat's status endpoint answered 2xx with the new token (`homechat_ok_at` set one second after the agent started, `last_error` null). The fork app was quit and its Login Item switched off (Alex), and its cursor was copied over. The agent and the updater were restarted unpaused, and the first read succeeded.
- 2026-11-15 11:14 ET: reinstalled from `main` `16ee2f7` (Alex approved); Alex granted Full Disk Access; the agent's snapshot confirms `granted`. PR #13 merged (`16ee2f7`), `main` CI green.
- 2026-11-15 11:00 ET: PR #13: the final review's fix pass (no Critical; 4 Important fixed, then 5 more from its send-safety review). The updater never leaves the agent without an app or stopped. HomeChat's pause still arrives while sends are stopped. `database_replaced` stays stopped until `reset-cursor` (272 tests).
- 2026-11-15 10:50 ET: PR #12 merged (`f076928`): runbooks for cutover, Stage U and Stage S.
- 2026-11-15 10:43 ET: PR #11 merged (`f269194`): Dependabot, plus an automerge job gated on Dependabot being both the PR author and the run's actor. Package.swift may change only on the imsg pin line.
- 2026-11-15 10:24 ET: PR #10 merged (`2c9262a`): the nightly updater: fetch, test, build, swap, health mark, roll back (259 tests; a green check counts only main's own push or dispatch runs, after the automated security review).
- 2026-11-15 10:15 ET: PR #9 merged (`77cffcb`): app bundle, signing and launchd; installed on the MacBook, idle (246 tests; signed build checks bundle ID + certificate, no cdhash).
- 2026-11-15 09:22 ET: PR #8 merged (`3926922`): commands and the run loop; SIGTERM finishes an in-flight send before exit (241 tests; send-safety review: no Critical, one Important carried to Task 10's `ExitTimeOut`).
- 2026-11-15 09:15 ET: PR #7 merged (`b58ab85`): status reports, HomeChat's pause (can only pause), permissions readouts, fork-running guard (228 tests; send-safety review: no Critical or Important).
- 2026-11-15 09:10 ET: PR #6 merged (`0068d31`): the send path on every route; polls while off; read-back to the end (206 tests, fake script runner; send-safety review: no Critical or Important).
- 2026-11-15 09:01 ET: PR #5 merged (`cd4538e`): unsends relayed from `MessageWatcher`; every uplink batch goes through one queue (165 tests).
- 2026-11-15 08:58 ET: PR #4 merged (`151891d`): reading through `IMsgCore` paging (158 tests; send-safety review: no findings).
- 2026-11-15 08:53 ET: PR #3 merged (`db5acc1`): `ChatQueries`; PR and `main` CI green.
- 2026-11-15 08:48 ET: PR #2 merged (`7551e40`): the safety core lifted (103 tests; send-safety review pass).
- 2026-11-15 08:41 ET: PR #1 merged (`69f9fb1`): scaffold; first CI run on `xcode-27` green (IMsgCore builds there).
- 2026-11-15: repo created (public, MIT).

## WHERE THINGS ARE
- Design, contract: `docs/specs/`. Plan: `docs/plans/`. Fork (frozen except cutover notes): `Goldalex98/msgblast-imessage`.
