# Status: imsg-companion

**Updated:** 2026-11-15 11:16 ET
**At:** Plan Tasks 1–13 are built, reviewed and merged. The agent is installed on the MacBook from `main` (`16ee2f7`, Apple Development signed). Its own snapshot reads Full Disk Access granted, sends off, no token. While the fork app runs, uplink stays blocked. Nothing has read real message content and nothing has been sent.
**Next:** HomeChat's §7 half, in `homechat-bot`'s own session: no PR exists for it yet. Then cutover (`docs/runbooks/cutover.md`; step 0a and the Full Disk Access grant are done).
**Phase:** Built; next are cutover and acceptance with Alex (`docs/runbooks/stage-u.md`, `stage-s.md`), after HomeChat's §7 deploy.
**Milestones:** Dependency proof ✓ · Scaffold ✓ · Safety core ✓ · Reading ✓ · Sending ✓ (built, never run against Messages) · Status and control ✓ · Packaging ✓ · Updates ✓ (built; no nightly run yet) · Runbooks ✓ · Cutover · Acceptance

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## RUNNING NOW
- CI (`ci.yml`) on PRs and pushes to `main`: tests, the ad hoc app build and the Dependabot diff check. The `automerge` job runs only on Dependabot's PRs.
- Dependabot (swift, daily, 3-day cooldown). No bump PR yet: the automerge live check (Task 12 Step 4) is pending.
- `ImsgCompanion.app` in `~/Applications` on the MacBook, under launchd (`io.github.goldalex98.imsg-companion`), installed 2026-11-15 11:14 ET from `16ee2f7`. Full Disk Access granted (the agent's own readout). No token, sends off, uplink blocked while the fork app runs. The 03:30 updater job is loaded; no nightly run has happened yet.

## QUEUED
- Cutover (`docs/runbooks/cutover.md`), then Stage U and Stage S.
- HomeChat's half (design §7, the contract's 2026-11-15 additions): `homechat-bot`'s own session and PRs, deployed before cutover.

## BLOCKED
- None.

## AWAITING Alex
- None for building. Cutover and acceptance need him later (grants, test contacts, his typed yes per real send).

## DONE
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
