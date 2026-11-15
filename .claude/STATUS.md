# Status: imsg-companion

**Updated:** 2026-11-15 08:59 ET
**At:** Plan Tasks 1–5 done (dependency proof, scaffold, safety core, `ChatQueries`, reading through `IMsgCore`); Task 6 (unsends) in progress. Library code and tests only: nothing reads the real `chat.db`, nothing is installed, nothing sent.
**Next:** Plan Task 6: unsends from the watcher, and one uplink queue.
**Phase:** Building (plan Tasks 2–13); then cutover and acceptance with Alex, after HomeChat's §7 deploy.
**Milestones:** Dependency proof ✓ · Scaffold ✓ · Safety core ✓ · Reading ✓ · Sending · Status and control · Packaging · Updates · Cutover · Acceptance

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## RUNNING NOW
- CI (`ci.yml`) on PRs and pushes to `main`.

## QUEUED
- Plan Tasks 6–13 (`docs/plans/2026-11-15-imsg-standalone-agent.md`).
- HomeChat's half (design §7, the contract's 2026-11-15 additions): `homechat-bot`'s own session and PRs, deployed before cutover.

## BLOCKED
- None.

## AWAITING Alex
- None for building. Cutover and acceptance need him later (grants, test contacts, his typed yes per real send).

## DONE
- 2026-11-15 08:58 ET: PR #4 merged (`151891d`): reading through `IMsgCore` paging (158 tests; send-safety review: no findings).
- 2026-11-15 08:53 ET: PR #3 merged (`db5acc1`): `ChatQueries`; PR and `main` CI green.
- 2026-11-15 08:48 ET: PR #2 merged (`7551e40`): the safety core lifted (103 tests; send-safety review pass).
- 2026-11-15 08:41 ET: PR #1 merged (`69f9fb1`): scaffold; first CI run on `xcode-27` green (IMsgCore builds there).
- 2026-11-15: repo created (public, MIT).

## WHERE THINGS ARE
- Design, contract: `docs/specs/`. Plan: `docs/plans/`. Fork (frozen except cutover notes): `Goldalex98/msgblast-imessage`.
