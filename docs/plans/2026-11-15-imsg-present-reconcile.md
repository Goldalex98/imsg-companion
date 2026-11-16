# iMessage deletion reconcile (`present`): Mac half

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Once a day the agent tells HomeChat which messages still exist in `chat.db`, so HomeChat can drop its stored copies of messages deleted or unsent on the Mac. Nothing on the Mac is ever deleted or changed.

**Why a separate plan:** this was queued for the retired fork. HomeChat's server half is built. The wire shape and server rules are in `docs/specs/2026-11-08-imsg-uplink-contract.md` ("2026-11-15 additions (2)"). The standalone-agent plan (`docs/plans/2026-11-15-imsg-standalone-agent.md`) is closed.

**Global rules still apply:** read-only SQLite only, public repo (no real GUIDs, handles or hosts in code, tests, fixtures or docs), counts-only logs, never write `chat.db`.

## Task 14: Daily `present` request

**Files:**
- Create: `Sources/CompanionCore/PresentReconciler.swift`
- Modify: `Sources/CompanionCore/ChatQueries.swift` (a read-only `presentGUIDs`), `Sources/CompanionCore/CompanionModels.swift` (the `present` field on `UplinkBatch`, omitted from JSON when nil), `Sources/CompanionCore/UplinkClient.swift` and `UplinkSerializer.swift` (it posts through the same serializer, so it never overlaps a message batch), `Sources/CompanionCore/CompanionConfig.swift` (`lastPresentAttemptAt`, `lastPresentAt`, `presentAuthBlockedFor`), `Sources/CompanionCore/CompanionService.swift` (a public actor method `presentSnapshot(since:)` that reads through the actor's own private `reader`/`openReader()`, since `main.swift` cannot reach them), `Sources/CompanionCore/AgentStatus.swift` only if a counts-only status field is wanted (not required), `Sources/imsg-companion/main.swift` (a call in the existing message loop, after `service.tick()`, and a hidden `present-now` command for acceptance)
- Tests: `Tests/CompanionCoreTests/PresentReconcilerTests.swift`, additions to `ChatQueriesTests.swift`, `UplinkClientTests.swift` and `CompanionModelsTests.swift`

**Behaviour:**
- **When:** at most one attempt per 24 hours. `lastPresentAttemptAt` is written when a run starts, whatever the outcome, so a failure never makes the idle loop (paced 2 s) re-send: those requests share HomeChat's 120/min per-token budget with message batches. `lastPresentAt` (last `200`) is informational only. After a `401` the run is also blocked until the token or HomeChat URL changes (`presentAuthBlockedFor` holds a hash of both). Due runs happen when the message loop is idle: the last `tick()` ended `.idle`, caught up, with no pending retry, so a normal batch is never waiting. Not while paused, the fork guard is on, `database_replaced` is set, or there is no token. A failed or skipped run is not retried until the next day.
- **What it reads (read-only):** with the existing `ChatQueries` connection, `presentGUIDs(since:)` returns, per `chat.guid`, every `message.guid` whose date is at or after `since` (`since` = now − 14 days; use the same date expression as `firstRowID(since:)`, which handles both nanosecond and second dates). `chat.db` dates are Apple reference time (seconds since 2001-01-01, often in nanoseconds); the wire `since`, including a moved `since`, is **Unix epoch seconds** (add 978,307,200 after scaling). Getting this wrong makes HomeChat drop `present` as too old every day, silently. It lists every message row in the chat, including reactions, system rows, unsent rows and rows the uplink skips. A superset is safe: extra GUIDs are harmless, a missing one lets HomeChat delete. A message in two chats appears under both. Rows with no chat are left out.
- **Which threads:** only chats that have at least one row in the window. A chat with none is not sent (HomeChat treats an empty list as "ignore").
- **Batching:** one entry per thread. A thread with more than 2000 GUIDs moves its own `since` later (to the date of its 2000th newest message, rounded up to the next whole second) until the list fits, at most 20 moves per thread; if the newest 2000 rows share one second or the bound is hit, the thread is left out of today's run and counted. The list is never truncated for the original `since`. Entries are packed into requests of at most 200 entries and 900,000 bytes (`CompanionService.maxBodyBytes`). Each request is `{device_id, batch_id (new UUID), cursor: <the saved cursor, never advanced by this>, first_run: false, threads: [], messages: [], present: [...]}`. `cursor` must be the config's current cursor, and only after at least one accepted batch (never `nil`): a lower cursor makes HomeChat ignore `present`.
- **Completeness:** if any read for a thread throws, that thread is left out of today's run and the rest go. If the database was replaced mid-run (file identity changed), the whole run is abandoned.
- **Failure handling:** `401`, `413`, `422` or other 4xx: stop today's run, record a short `last_error`-style note (counts, no data) without halting message uplink (a rejected `present` is not a reason to stop messages; the message path keeps its own stop rules). `429`, `5xx` and offline: stop today's run, retry tomorrow. `"present_skipped": true` in a `200`: count it, treat the run as done. HomeChat's caps and stale-cursor skips are silent, so a run can answer `200` and still delete nothing; that is expected.
- **Never:** write or alter `chat.db`, call any send, launch or bridge API (`ForbiddenAPITests`), hold the message serializer across a long read, or log GUIDs or text.

- [ ] **Step 1: Failing tests** (synthetic `chat.db` fixture from `CompanionFixture`, a fake uplink recording bodies):
  - `presentGUIDs(since:)` returns every row in the window per chat, both date scales, and none before `since` or with no chat
  - a thread with 2001+ rows sends a later `since` and exactly the GUIDs at or after it; never a truncated list for the old `since`
  - requests split at 200 entries and at the byte limit, one entry per thread per request, each body valid against the contract (`messages: []`, `threads: []`, cursor equals the saved cursor)
  - not due inside 24 hours of the last attempt, whatever its outcome; due after; a `5xx` followed by 100 idle passes sends exactly one request
  - after a `401`, no request until the token or URL changes
  - the wire `since` is Unix epoch seconds for both chat.db date scales (2026-11-01T00:00Z encodes as 1793491200)
  - a thread whose newest 2000 rows share one second is left out, not truncated
  - not run while paused, fork running, `database_replaced`, no token, or when the last tick was not idle
  - `401`/`422` stop the run and leave message uplink untouched; `429`/`5xx`/offline stop the run with no same-day retry; `present_skipped` counts and completes
  - a read error on one thread omits only that thread
  - a message deleted from the fixture after a first run disappears from the next day's list, and the request body never contains message text
  - the encoded `UplinkBatch` has no `present` key when nil (normal batches unchanged)
- [ ] **Step 2:** `swift test`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement. Add `present: [PresentEntry]?` to `UplinkBatch` (`thread_guid`, `since` as an integer of Unix epoch seconds, `guids`; explicit `CodingKeys` for `thread_guid` like the existing models), encoded with `encodeIfPresent`. Add `ChatQueries.presentGUIDs(since:)` with bound parameters only. `PresentReconciler` takes the reader, config URL, a serializer-backed uplink, a clock and the idle signal as injected closures. Call it from the existing message loop in `main.swift` after `service.tick()`.
- [ ] **Step 4:** `swift build` then `swift test`. Expected: PASS.
- [ ] **Step 5:** Run `send-safety-reviewer` on the diff (reading and uplink). Fix Critical and Important findings test-first.
- [ ] **Step 6:** Commit, PR, merge on green. The reinstall on the MacBook needs Alex's yes (`scripts/install.sh`).
- [ ] **Step 7: Acceptance against HomeChat** (with Alex; test contact only; counts-only checks; no real send):
  - Pick a thread with a stored test message, at most 5 in the window (HomeChat's per-entry cap). Alex sends a test text from the test contact, waits until HomeChat stores it, then deletes that one message in Messages on the Mac (`chat.db` loses the row; Claude never deletes it).
  - Claude runs the agent's `present` request on demand (a hidden `present-now` command, or wait for the daily run) and HomeChat's session confirms: the stored copy is gone (`n_removed` 1 on the `imsg_ingest` log line), and the flag, if one was open, closed `deleted` only when no newer inbound text remained.
  - Check nothing on the Mac changed: the message count in `chat.db` for the thread is one lower and nothing else moved; no message was sent, marked read or edited by the agent (the ledger has no new record).
  - Also check a thread with other messages is untouched (stored counts the same), and that a run with the stale-cursor case sent by hand is ignored (log shows `present_stale`).
  - Pass line: the deleted message is dropped from HomeChat, all other stored messages stay, and the Mac is unchanged. Say which of these were seen versus only configured.

## Notes

- HomeChat's caps (5 deletions per entry, 20 per request) mean a bulk delete on the Mac is not reconciled. That is by design on HomeChat's side; the agent does not try to work around it.
- A thread deleted whole on the Mac sends no entry (HomeChat ignores an empty list), so its stored copies are not reconciled.
- Edits are not covered here (deferred in the main plan).

## Changes from the plan review (2026-11-16)

The one independent plan review found the plan sound with changes. Built as follows, superseding the text above where they differ:

- **`since` is a whole Unix second, used for both the read and the wire.** The read lists every row dated at or after `since` minus one second. HomeChat keeps `sent_at` to the second, so a row just before a fractional boundary (or one whose stored time rounds up) is still listed. The same margin applies to a moved `since`.
- **Moved `since`:** the first of `ceil(d) + 1` and `floor(d) + 2` (where `d` is the 2000th newest row's date) whose list, margin included, fits in 2000. One move always fits, so there is no 20-move loop. An empty list (the newest 2000 rows share one second) leaves the thread out, counted.
- **Rows are grouped by `chat.guid`**, joined across every chat row with that GUID, with GUIDs deduplicated. Rows with a NULL or empty GUID are skipped. A thread whose GUID, or any of whose message GUIDs, is over 200 characters is left out, because one bad string makes HomeChat drop the whole `present`.
- **Due** means the tick just returned `.idle` with `pendingEstimate == 0` and a cursor, and the config is not paused and has a token. `lastPresentAttemptAt` is stamped only after those checks pass, so a busy moment doesn't use up the day.
- **One read for all threads.** If it fails, or the file at the path changed before or after it, the whole run is abandoned (nothing sent). This replaces "a read error on one thread omits only that thread".
- **Atomic within one loop pass:** the reconciler reads and posts in one call, straight after `service.tick()`, so no message batch lands between its read and its posts.
- **`present-now`** writes `present-request.json`. The running agent's next idle pass runs once, ignoring only the daily gate (not a 401 block), and writes counts-only `present-result.json`. A second process would bypass the serializer and has no Full Disk Access.
- After `reset-cursor`, HomeChat keeps the higher old cursor, so `present` is ignored as `present_stale` until the agent's cursor climbs past it. Expected, not a failure.
