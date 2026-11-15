# Status: imsg-companion

**Updated:** 2026-11-15 08:50 ET
**At:** Plan Tasks 1–3 done (dependency proof, scaffold, safety core); Task 4 (`ChatQueries`) in review as PR #3. Library code and tests only: nothing reads the real `chat.db`, nothing is installed, nothing sent.
**Next:** Plan Task 5: reading through `IMsgCore` (`CompanionService`).
**Phase:** Building (plan Tasks 2–13); then cutover and acceptance with Alex, after HomeChat's §7 deploy.
**Milestones:** Dependency proof ✓ · Scaffold ✓ · Safety core ✓ · Reading · Sending · Status and control · Packaging · Updates · Cutover · Acceptance

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## RUNNING NOW
- CI (`ci.yml`) on PRs and pushes to `main`.

## QUEUED
- Plan Tasks 5–13 (`docs/plans/2026-11-15-imsg-standalone-agent.md`).
- HomeChat's half (design §7, the contract's 2026-11-15 additions): `homechat-bot`'s own session and PRs, deployed before cutover.

## BLOCKED
- None.

## AWAITING Alex
- None for building. Cutover and acceptance need him later (grants, test contacts, his typed yes per real send).

## DONE
- 2026-11-15 08:48 ET: PR #2 merged (`7551e40`): the safety core lifted (103 tests; send-safety review pass).
- 2026-11-15 08:41 ET: PR #1 merged (`69f9fb1`): scaffold; first CI run on `xcode-27` green (IMsgCore builds there).
- 2026-11-15: repo created (public, MIT).

## WHERE THINGS ARE
- Design, contract: `docs/specs/`. Plan: `docs/plans/`. Fork (frozen except cutover notes): `Goldalex98/msgblast-imessage`.
