# Status: imsg-companion

**Updated:** 2026-11-15 08:55 ET
**At:** Plan Task 2: the repo scaffold, CI and the contract amendment are in review. Task 1 (`IMsgCore` 0.21.0 as a pinned dependency) passed on the MacBook. Nothing built beyond a placeholder; nothing sent.
**Next:** Plan Task 3: lift the companion safety core from the fork.
**Phase:** Building (plan Tasks 2–13); then cutover and acceptance with Alex, after HomeChat's §7 deploy.
**Milestones:** Dependency proof ✓ · Scaffold · Safety core · Reading · Sending · Status and control · Packaging · Updates · Cutover · Acceptance

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## RUNNING NOW
- CI (`ci.yml`) on PRs and pushes to `main`.

## QUEUED
- Plan Tasks 3–13 (`docs/plans/2026-11-15-imsg-standalone-agent.md`).
- HomeChat's half (design §7, the contract's 2026-11-15 additions): `homechat-bot`'s own session and PRs, deployed before cutover.

## BLOCKED
- None.

## AWAITING Alex
- None for building. Cutover and acceptance need him later (grants, test contacts, his typed yes per real send).

## DONE
- 2026-11-15: repo created (public, MIT).

## WHERE THINGS ARE
- Design, contract: `docs/specs/`. Plan: `docs/plans/`. Fork (frozen except cutover notes): `Goldalex98/msgblast-imessage`.
