# Status: imsg-companion

**Updated:** 2026-11-15 09:23 ET
**At:** Plan Tasks 1–5 done (dependency proof, scaffold, safety core, `ChatQueries`, reading through `IMsgCore`, unsends, the send path, status and control, commands and the run loop); Task 10 (app bundle, signing, launchd) in progress. Library code and tests only: nothing reads the real `chat.db`, nothing is installed, nothing sent.
**Next:** Plan Task 10: build, sign and install the app under launchd with sends off and no token; then Alex grants Full Disk Access himself.
**Phase:** Building (plan Tasks 2–13); then cutover and acceptance with Alex, after HomeChat's §7 deploy.
**Milestones:** Dependency proof ✓ · Scaffold ✓ · Safety core ✓ · Reading ✓ · Sending ✓ (built, never run against Messages) · Status and control ✓ · Packaging · Updates · Cutover · Acceptance

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## RUNNING NOW
- CI (`ci.yml`) on PRs and pushes to `main`.

## QUEUED
- Plan Tasks 10–13 (`docs/plans/2026-11-15-imsg-standalone-agent.md`).
- HomeChat's half (design §7, the contract's 2026-11-15 additions): `homechat-bot`'s own session and PRs, deployed before cutover.

## BLOCKED
- None.

## AWAITING Alex
- None for building. Cutover and acceptance need him later (grants, test contacts, his typed yes per real send).

## DONE
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
