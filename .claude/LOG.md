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

## 2026-11-15 10:16 ET — Task 10
- PR #9 merged `77cffcb` (PR CI green, including the new ad hoc app build). The signed build has hardened runtime, the Apple Events entitlement, and a designated requirement of bundle ID plus Apple anchor with no cdhash. `ExitTimeOut` 120 (the brief said 90; a fetch plus script plus read-back can take about 97 s).
- Installed on the MacBook with no token and sends off. `launchctl print` shows it running with parent pid 1. The agent's own snapshot (`agent-status.json`, which `status` prints) reads `full_disk_access: denied`. A terminal's readout showed `granted`, because a terminal's grants are its own, not the agent's. That is why the snapshot file exists.
- Install fix: `launchctl bootout` returned before the old process had exited, and bootstrap failed with error 5. `install.sh` now waits for the unload. A reinstall over the running agent stopped it in about 2 s.

## 2026-11-15 10:26 ET — Task 11
- PR #10 merged `2c9262a` (PR CI green). `imsg-companion update` runs once per night from launchd at 03:30. It reads main's head over the public API, unauthenticated, and needs that sha's newest `ci.yml` run on main to have succeeded. It skips if HomeChat hasn't answered in 30 minutes, and defers while a send has been in progress more than 10 minutes. It runs the tests and builds the app into `build/`, keeps the old app as `previous/` and swaps the new one in. It rolls back unless the new agent writes a health mark (read and HomeChat reachable) within 180 s. A failed sha is never retried.
- The automated security review found that the green check trusted any run of the sha. A pull request run, including one from a fork's branch named main, could count. Now only runs whose event is push or workflow_dispatch, on main, for that sha count. A test failed first, and the live API carries those fields.
- Not run for real: no nightly update has happened. The installed build predates `update`, so it needs a reinstall first.

## 2026-11-15 10:45 ET — Tasks 12 and 13
- PR #11 merged `f269194` (PR CI green; `automerge` skipped, as it should be on a non-Dependabot PR). The automated security review found that the gate trusted the PR author alone. It now also needs `github.actor` to be Dependabot. `scripts/dependabot-diff-ok.sh`, the base commit's copy, accepts only `Package.resolved` and the exact-tag imsg pin line. Nine synthetic diff cases run in CI. Not adopted: `dependabot/fetch-metadata`, a third-party action. Pending until the first real bump: the 3-day wait, a merge commit, a dispatched green `main` run, and whether Dependabot rewrites an `exact:` pin.
- Runbooks in `docs/runbooks/`:
  - Cutover proves HomeChat's §7 deploy by starting the agent locally paused with the new token: the health mark's `homechat_ok_at` is set only by a 2xx `POST /imsg/status`.
  - The fork's cursor is copied by a short script while both apps are stopped.
  - Rollback also stops the updater job.
  - U8 forces a rollback by pausing the agent locally before an update. "HomeChat unreachable" is the agent stopped for over 30 minutes.
  - "A send in progress defers" can't be staged with sends off, so it stays test-only.

## 2026-11-15 11:00 ET — final review and its fix pass
- A fresh Opus reviewer read the whole branch. No Critical findings. Four Important ones, each fixed with a test that failed first:
  - The updater's swap could leave no app at all, and the updater runs from that app. The new app is now staged beside the old one and swapped in by checked renames.
  - A stopped send channel also cut off HomeChat's pause. A control-only poll now keeps it reachable.
  - `database_replaced` cleared itself once new rows passed the old cursor. It is now kept in the config until `reset-cursor`.
  - A pause at update time always rolled back. The updater now skips that night.
- The send-safety reviewer then found five holes in those fixes, all fixed test-first:
  - A failed rename in a rollback could nest the old app inside the bad one.
  - A pause during the build or the health wait condemned a good commit.
  - An agent left stopped stayed stopped. The updater now starts it again, so cutover stops the updater job too.
  - A 401 on the control poll kept polling.
  - `reset-cursor` counted the first-run window back from the reset, not from the replacement.
- Deferred minors (the plan's ledger):
  - The unsend watcher stays on the old inode after a replacement.
  - A stray SIGTERM exits 0, so launchd doesn't restart it.
  - Updater subprocesses have no timeout.
  - `flush()` can post the same unsend twice.
  - Expiry relies on the Mac's clock.
  - From the second review: unchecked `try?` on the sticky write, an unchecked `rm` of `previous`, and `stopAgent` giving up silently after 130 s.
- Tests: 272 pass on the MacBook. Nothing ran against real data, and nothing was sent.

## 2026-11-15 11:16 ET — reinstalled with the updater build
- Alex granted Full Disk Access and approved the reinstall. Built from `main` `16ee2f7`: Apple Development authority, `codesign --verify --strict` passes, and the requirement has no cdhash.
- `install.sh` reloaded both jobs, and the agent is running. Its first snapshot from the new build reads `full_disk_access: granted`, sends off, `last_error` null, `fork_running` true.
- The dependency probe folder from Task 1 was deleted, with Alex's yes.
- HomeChat's §7 changes don't exist yet: no `homechat-bot` PR covers them. Cutover waits on that repo's session.

## 2026-11-15 14:24 ET — cutover
- HomeChat's §7 half was deployed and live, with 0 unfinished sends (HomeChat's session, steps 1–2).
- Steps 3 and 5 ran as one pipe: HomeChat's own CLI issued the device token on the server, and it went straight into `setup`'s stdin. It never appeared in a terminal, chat or log. `setup` reads the token from stdin, so the pipe works unattended. The device ID exists only once a config is written. The agent had no `companion.json` until step 4's `pause` saved one, so step 4 has to run before the token is issued.
- Step 6, the §7 proof: started paused, `homechat_ok_at` was set one second after start, `last_error` null.
- Step 7: Alex quit the fork app and switched off its Login Item. Both `fork_running` readouts were false.
- Step 8: after `bootout`, the agent took about 18 s to exit (the graceful-exit window). Wait for the process to go before copying the cursor.
- Step 9: the fork's cursor was copied. The new config had none.
- Step 10: resumed and both jobs started. `read_ok_at` was set after the start, with `paused` false, `last_error` null, `fork_running` false and the cursor equal to the copied one. No uplink batch yet (`last_uplink_at` null): no new rows past the cursor in that minute.
- No sends. Nothing wrote `chat.db`. Only counts and states were read.
- Still to do: the fork's token stays live until it is revoked before Stage S, so HomeChat refuses every send until then.

## 2026-11-15 15:05 ET — Stage U: U1, the Contacts entitlement and the health-mark precision bug
- U1 passed: after a restart the agent started from launchd at login. After `launchctl kill SIGKILL` it came back with a new pid within 15 s. Alex confirmed the Full Disk Access listing.
- Contacts: `prompt-contacts` answered `denied` at once, with no prompt, and the state stayed not determined. Hardened runtime refuses Contacts unless the signature carries `com.apple.security.personal-information.addressbook`, and the app had only Apple Events. PR #16 adds it. A test pins the pair, `build-app.sh` checks each key is `true`, and `ForbiddenAPITests` bans the Contacts write types. The design and plan record it.
- U8, first live run, kickstarted under launchd for `f1281f0`:
  - It built, signed and swapped in the app with no Keychain prompt.
  - The new agent kept Full Disk Access and wrote a complete health mark.
  - The updater still rolled back after 180 s and condemned the commit. `health.json` is encoded `.iso8601`, whole seconds, so an agent started in the same second as the swap reads back as earlier than the updater's sub-second start time. The installed path could never pass. The unit tests' fake mark used `.distantFuture`, which hid it.
  - Fix: the updater floors its start time to whole seconds. A test through the real `HealthMarkStore` failed first. Further tests cover a mark from the previous second and a same-second mark of another version.
  - The rollback itself worked live: the old app came back and the agent ran again.
- From the fix's send-safety review, not taken: the daily send cap can count one fewer dispatch at its exact 24 h edge, because ledger times are stored in whole seconds (Minor). This is noted for the deferred ledger minors.

## 2026-11-15 17:08 ET — Stage U: install by hand, Contacts, U2–U4
- Fable reviewed both Stage U diagnoses and proved them from live logs.
  - Contacts: tccd logged "requires entitlement com.apple.security.personal-information.addressbook but it is missing". The earlier empty log search used the wrong predicate. In zsh, `log` is a builtin, so use `/usr/bin/log`.
  - Updater: launchd spawned the agent about 0.06 s after the updater's `started`, and the mark held whole seconds.
  - Fable also found that kickstarting the installed (old) updater would rerun the bug. It would probably condemn PR #17's commit too, so the fix was installed by hand instead.
- Apple's documentation pages render with JavaScript, so a page fetch sees an empty shell. Their content is public JSON at `developer.apple.com/tutorials/data/documentation/<path>.json`. That source gives the addressbook entitlement as read-write access to contacts.
- Install: `build-app.sh` then `install.sh` from `main` `2c8de3f`. The signature names the identifier and certificate, with no cdhash, and carries both entitlements. Full Disk Access survived. Runbook step 0a's `codesign -dv` prints no Authority lines, so it now uses `-dvv`.
- Contacts: the prompt appeared and Alex allowed it. tccd logged the prompt and created the grant. The running agent kept reading `unknown` until `kickstart -k`, because the answer is cached per process. The terminal's own readout reports the host app's permission, not the agent's. U9 notes the restart.
- U2 and U3 pass. HomeChat's session gave the counts, read-only:
  - Rows 232746–232750 are all stored once as text. The fork's last row was 232745.
  - There are no duplicate guids; guid is the primary key.
  - The test text was stored at the second the agent's batch was accepted. The 5 s check is timed from the agent reading the row, because this terminal has no Full Disk Access.
- U4 passes on HomeChat's stored state. A flag opened on the test question, then closed with `replied` when Alex's reply was stored.
  - HomeChat's flagger runs every 30 minutes. A new flag is hidden for 3 hours unless it names a date within 48 hours, so "seen on the phone" can't be checked the same day. The runbook's U4 now says so.
  - The flag was opened by a manual flagger pass that HomeChat's session ran. It used one call from HomeChat's daily cap and sent no message.

## 2026-11-15 17:12 ET — PR #18 merged; updater not yet run
- PR #18 merged as `b59f35e` once its CI run was green.
- The updater has no scheduled result yet. It was reloaded by the 15:16 reinstall (`runs = 0`), and `updater.log` holds only the 15:01 `rolled_back` of `f1281f0`. Its first 03:30 run is 2026-11-16, and it should install `b59f35e`. That run is the first live proof of the fixed health check.

## 2026-11-15 19:05 ET — Stage U: U5
- Catch-up: the agent was booted out (its process exited about 12 s later). Alex's phone sent 2 texts, then the agent was bootstrapped again. The cursor moved 232756 → 232758, and the batch was accepted at 18:58:35. HomeChat holds exactly 232757–232758, both text.
- Offline retry: Alex turned Wi-Fi off, wrote one message on the Mac and reconnected. The unified log shows failed uploads at 19:00:24 (-1004), 19:00:29 (-1009) and 19:00:40 (-1009), with a growing gap, then success at 19:01:02. HomeChat stored exactly row 232759. The status `last_error` was never seen set: snapshots are about a minute apart, and none fell inside the window. A phone text can't drive this test, because an offline Mac doesn't receive it. The runbook now says so, and checks the OS log.
- SSN scrub: HomeChat counts 1 stored text with the marker and 0 with the digits, dashed or not. Where the removal happened wasn't asked. The pass condition doesn't depend on it.
- Code skip: a code text in a thread Alex writes in (232761) is stored with its text. The never-written-thread case was not run: no sender was available. It stays covered by unit tests only. The runbook now notes that a real short-code text would do.
- Nothing was sent. Only counts, ROWIDs, kinds and times were read.

## 2026-11-15 19:13 ET — Stage U: U6
- The first try didn't count. The question was sent from Alex's own phone, so it was stored as his outgoing row (232762) and took the thread out of the flag queue. U6 needs the test contact to send the question and to unsend it from their own phone.
- Second try: row 232763 was received at 19:10:00. HomeChat's session ran one flagger pass by hand, and flag 23 opened at 19:10:58 with reason `date`, visible at once. The unsend came at 19:11:24. HomeChat stored the row once as `unsent` with its text wiped, and closed flag 23 with `unsent` in the same second. The agent's cursor stayed at 232763, and `watcher_restarts` stayed 0.
- The agent's `last_uplink_at` stayed at the message's 19:10:00 after the unsend relay. The unsend goes through its own path. Not a failure: noted for the status readout.
- HomeChat-side finding, outside this repo: the bot's nudge loop sent a WhatsApp nudge for flag 23 at 19:11:23, 1 s before the unsend closed it. Nothing withdraws a nudge whose flag closes as `unsent`, so a numbered reply to it points at a closed flag. This is for `homechat-bot`'s own session to weigh. It changes nothing here.
- Whether the nudge appeared on Alex's phone is unconfirmed: "sent" means WhatsApp accepted it.

## 2026-11-15 20:18 ET — Stage S: revoke, S0, S1
- Alex chose to skip the rest of Stage U (U7, U8's test steps and U9). Unproven live as a result: a pause from WhatsApp, and how an unsaved number is handled. The updater's install proves itself at 03:30.
- `sends on` was run at the Mac on Alex's say-so. HomeChat's session confirmed that no send had ever been queued, then revoked the fork's device token at 19:33:58. The new Mac is the only linked device.
- HomeChat has no chat ROWIDs: its threads are keyed by chat guid. The chat ROWID was read on the Mac with one read-only query that prints integers only. The runbook now says so.
- First preflight: refused with -1712 (AppleEvent timeout) while the Automation prompt waited. tccd created the entry 20 s later. After Alex's Allow it was `ready`, and the readout showed `granted`.
- S1: the test contact's question arrived in a different 1:1 chat for the same test contact (another handle, labelled SMS). Alex approved one reply in HomeChat. The agent sent exactly one row in that chat over iMessage: read-back `confirmed`, reported to HomeChat 3 s after dispatch. Alex confirmed the test phone got it. The ledger keeps `text_length` and `text_sha256`, with no text.
- Not run: S2–S5 and the group, SMS and RCS preflights.

## 2026-11-15 20:19 ET — acceptance closed
- Alex called it done after S1 and kept sends on. Each case not run stays unproven live, as listed in STATUS. The first check of tonight's 03:30 updater run, its first scheduled install, is the next session's opening task.

## 2026-11-15 — deletion reconcile (`present`) queued here
- The Mac half was queued for the retired fork. HomeChat's server side is built, so the contract now states `present` as HomeChat's code accepts it (2026-11-15 additions (2)) and a new small plan (`docs/plans/2026-11-15-imsg-present-reconcile.md`, Task 14) covers the agent's side. The standalone-agent plan stays closed.
- Decided in the docs: a separate present-only request once a day, 14-day window, per-thread `since` moved later past 2000 GUIDs, a superset of GUIDs (every row in the chat), never blocking message uplink, no same-day retry. HomeChat deletes at most 5 stored messages per entry and 20 per request, silently, so bulk deletes are not reconciled.
- Docs only. Nothing built, no code changed.

## 2026-11-16 06:00 ET — first scheduled updater install
- The 03:30 updater run built, tested and installed `dfdf468` (PR #21's merge, docs only) and recorded `installed` at 03:31. That is U8's install case seen live, with the fixed health check from PR #17.
- Checked on the MacBook at 05:57: the agent process started 03:31:07, `read_ok_at` advancing, `homechat_ok_at` within the 15-minute status cadence, `last_error` null, not paused, sends on. `failed_commits` still lists only `f1281f0`.
- Automation reads `unknown` after any restart: `LastScriptResult` lives in memory, so the readout shows `granted` again only after the next preflight or send. The TCC grant itself was not re-checked.
- `last_uplink_at` is null since the restart: no messages arrived overnight. Uplink and sending on this build are unproven until the next message.
- `agent.log` holds only the Contacts framework's hourly `Could not fetch group ... making it a delete change type` lines, logged by the Contacts framework inside the agent process, not by the agent's own code.

## 2026-11-16 06:35 ET — deletion reconcile built
- Alex asked to build the plan. It had no recorded independent review, so the plan review ran first (Fable): sound with changes. The two that could delete a real stored message: a fractional `since` (a row just before it unlisted, yet stored at a second HomeChat counts inside the window) and duplicate chat rows for one GUID (a duplicate entry drops all of `present`; one row's list alone is incomplete). Both are fixed and tested. All changes are in the plan's "Changes from the plan review" section.
- Built on branch `present-reconcile`: `PresentReconciler`, `ChatQueries.presentRows`, `CompanionService.presentSnapshot`, `present` on `UplinkBatch`, `present_skipped` on the ack, three config fields, and a hidden `present-now` (a request file the running agent picks up).
- MacBook gate: build, 300 tests, app build all pass. The send-safety review (Opus) found no Critical or Important issues. One of its Minors was re-graded Important by effect and fixed test-first: if the daily stamp can't be saved, no run happens, because otherwise every 2 s idle pass would post and use up HomeChat's shared per-token budget.
- Deferred minors: the 200-character check counts graphemes, not code points (it can only cause a `present_skipped`, never a deletion); the daily query scans the whole message table on the service actor; a message Messages moves between chats is deleted from the old thread's stored copy (HomeChat's cap of 5 applies).
- Not proven: the `main.swift` wiring, and any exchange with HomeChat (Step 7).
