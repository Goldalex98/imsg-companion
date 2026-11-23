# Log: imsg-companion

Append only. Newest at the bottom. Public: no personal data.

Older entries: [LOG-archive-2026-11-23.md](LOG-archive-2026-11-23.md).

## 2026-11-16 06:35 ET — deletion reconcile built
- Alex asked to build the plan. It had no recorded independent review, so the plan review ran first (Fable): sound with changes. The two that could delete a real stored message: a fractional `since` (a row just before it unlisted, yet stored at a second HomeChat counts inside the window) and duplicate chat rows for one GUID (a duplicate entry drops all of `present`; one row's list alone is incomplete). Both are fixed and tested. All changes are in the plan's "Changes from the plan review" section.
- Built on branch `present-reconcile`: `PresentReconciler`, `ChatQueries.presentRows`, `CompanionService.presentSnapshot`, `present` on `UplinkBatch`, `present_skipped` on the ack, three config fields, and a hidden `present-now` (a request file the running agent picks up).
- MacBook gate: build, 300 tests, app build all pass. The send-safety review (Opus) found no Critical or Important issues. One of its Minors was re-graded Important by effect and fixed test-first: if the daily stamp can't be saved, no run happens, because otherwise every 2 s idle pass would post and use up HomeChat's shared per-token budget.
- Deferred minors: the 200-character check counts graphemes, not code points (it can only cause a `present_skipped`, never a deletion); the daily query scans the whole message table on the service actor; a message Messages moves between chats is deleted from the old thread's stored copy (HomeChat's cap of 5 applies).
- Not proven: the `main.swift` wiring, and any exchange with HomeChat (Step 7).

## 2026-11-16 07:12 ET — deletion reconcile merged
- Alex said merge after PR #23's CI was green. Merged as `8f51f54` with a merge commit. Merging is the deploy here: the 2026-11-17 03:30 updater installs `main`'s head, and the agent's first idle pass after that runs `present` without anyone watching. That is why the merge waited for his yes.
- Unproven until then: the install, the `main.swift` wiring, and HomeChat accepting the request.

## 2026-11-23 — Moved from STATUS (size trim)
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

## 2026-11-23 11:30 ET — live check, Dependabot, cleared queue
- Checked on the MacBook: the agent runs `225c245` (main's head), installed by the 03:30 updater; health good, last uplink 10:11 ET, HomeChat status 2xx. The daily `present` run wrote `done` for 92 threads. The 2026-11-17 install check queued on 11-16 is answered by this.
- Dependabot had failed every run since 2026-11-15: "Branch 'dependabot' already exists and causes a Git ref namespace conflict." That was this repo's own merged feature branch from PR #11 (`8f1ca4c`). Alex said fix it; the branch was already gone from GitHub (repo last pushed 2026-11-22 18:20 ET, after the last failed run). The local `origin/dependabot` was stale and is pruned. No Dependabot run has happened since, so the fix is unproven until the next scheduled run.
- Alex says he ran the deletion reconcile's Step 7 acceptance at some point and it worked; it was never logged. Recorded on his word, with no run record or HomeChat readback here.
- Alex declined the skipped acceptance cases (S2–S5, U7, U9, group/SMS/RCS preflights) for good: "clear these out. Don't nudge." They are off the queue and appear only as one not-proven line in STATUS EVIDENCE. Don't suggest them again.
- The unsent-nudge finding (LOG 2026-11-15 19:13) went to `homechat-bot` as issue #426, at Alex's OK.
