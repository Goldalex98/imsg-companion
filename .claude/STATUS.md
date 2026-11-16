# Status: imsg-companion

**Updated:** 2026-11-16 07:15 ET
**At:** In use. The agent runs `dfdf468` (installed by the 03:30 updater) under launchd with Full Disk Access and Contacts granted (Automation reads `unknown` until its next script run), not paused, **sends on**. One approved reply has been sent (S1). The fork's token is revoked.
**Next:** after 2026-11-17 03:30, check that the updater installed `main`'s head (with the deletion reconcile) and that the first daily `present` run wrote `present-result.json` (counts only). Then plan Step 7 acceptance with Alex.
**Phase:** In use. Acceptance closed by Alex after S1, with sends left on.
**Milestones:** Dependency proof ✓ · Scaffold ✓ · Safety core ✓ · Reading ✓ · Sending ✓ (S1 live) · Status and control ✓ · Packaging ✓ · Updates ✓ (rollback and scheduled install both seen live) · Runbooks ✓ · Cutover ✓ · Acceptance ✓ (U1–U6, S0–S1; rest skipped by Alex)

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## RUNNING NOW
- CI (`ci.yml`) on PRs and pushes to `main`: tests, the ad hoc app build and the Dependabot diff check. The `automerge` job runs only on Dependabot's PRs.
- Dependabot (swift, daily, 3-day cooldown). No bump PR yet: the automerge live check (Task 12 Step 4) is pending.
- `ImsgCompanion.app` in `~/Applications` on the MacBook, under launchd, running `dfdf468` since 2026-11-16 03:31 ET (installed by the nightly updater). Full Disk Access and Contacts granted; Automation reads `unknown` because it is remembered per process and no script has run since the restart (the grant itself was not re-checked). Token in the Keychain, not paused, sends on (Alex, 2026-11-15 19:16). The updater runs nightly at 03:30.
- The fork app: quit, Login Item off, still installed and paused as the fallback. Its token is revoked, so a rollback needs a fresh one (`cutover.md`).

## QUEUED
- Check the 2026-11-17 03:30 install and the first `present` run.
- Deletion reconcile Step 7 acceptance with Alex (test contact; `present-now`; HomeChat's session confirms counts).
- Optional, only if Alex asks: the skipped acceptance cases (DONE 20:17).
- For `homechat-bot`'s session: a WhatsApp nudge isn't withdrawn when its flag closes as `unsent` (LOG 19:13).

## BLOCKED
- None.

## AWAITING Alex
- None.

## DONE
- 2026-11-16 07:12 ET: PR #23 merged (`8f51f54`) on Alex's yes: the deletion reconcile (`present`), plan Task 14. PR CI green (43858489495). Built and unit-tested only: not installed, never run against HomeChat. The 03:30 updater installs it, and the first daily run follows on its own (HomeChat deletes at most 5 stored copies per thread).
- 2026-11-16 06:00 ET: the first scheduled updater run (03:30) installed `main`'s head `dfdf468` (`installed`, 03:31). The health mark kept moving afterwards (reads every few seconds, HomeChat status 2xx on its 15-minute cadence), `last_error` null, `watcher_restarts` 0, `previous/` holds the `2c8de3f` app. No messages arrived overnight (`last_uplink_at` null since the restart), so the new build's uplink and send are not yet exercised.
- 2026-11-15 20:17 ET: Alex closed acceptance after S1 and kept sends on. Not run, so unproven live: S2–S5 (group, SMS with accents and emoji, changed participants, expiry), group/SMS/RCS preflights, a pause from WhatsApp (U7), an unsaved number (U9), and U8's test cases beyond tonight's scheduled install. `"$BIN" sends off` at the Mac is the proven stop.
- 2026-11-15 20:13 ET: S1 passed. Alex approved one reply in HomeChat to the test contact. The agent sent it once (`sent`, `sent_service` `iMessage`, read-back `confirmed`), reported it 3 s after dispatch, and the test phone received it (Alex). The ledger record has no text field. The reply went to the thread the question arrived in (a second 1:1 chat for the test contact, labelled SMS), not the preflighted one.
- 2026-11-15 19:48 ET: S0 passed for the iMessage 1:1: preflight `ready`, `automation_messages: granted` after Alex allowed the prompt (the first try timed out at -1712 while the prompt waited). Group, SMS and RCS preflights not run.
- 2026-11-15 19:34 ET: the fork's token revoked by HomeChat's session (Alex approved). Zero sends had ever been queued. The new Mac is the only linked device.
- 2026-11-15 19:16 ET: Alex chose to skip the rest of Stage U (U7, U8's test steps, U9) and move to Stage S. Unproven live as a result: a pause from WhatsApp, and an unsaved number's handling. U8's install runs on its own at 03:30. Alex approved revoking the fork's token (handed to HomeChat's session, per the runbook). `sends on` run at the Mac on Alex's say-so; snapshot shows `sends_enabled: true`. Nothing sent: HomeChat still refuses sends until the revoke.
- 2026-11-15 19:13 ET: the U6 flag's WhatsApp nudge was seen on Alex's phone (first phone-side proof for a flag).
- 2026-11-15 19:12 ET: U6 passed. A test-contact question was flagged (`date`, visible at once), then unsent. HomeChat marked the row `unsent`, wiped its text and closed the flag with `unsent` within the same second the agent relayed it. `watcher_restarts` stayed 0. HomeChat-side finding, for `homechat-bot`: the WhatsApp nudge went out 1 s before the unsend and nothing withdraws it.
- 2026-11-15 19:07 ET: PR #19 merged (`0ae9902`): U5 results and runbook notes. PR CI green; `main` push CI 43778528893 green.
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
