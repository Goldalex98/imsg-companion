# Status: imsg-companion

**Updated:** 2026-11-23 11:30 ET
**Lifecycle:** active
**Verified:** 2026-11-23
**At:** In daily use and up to date. Texts reach HomeChat, approved replies send, and the nightly deletion check runs.
**Next:** Confirm Dependabot works again now that the branch blocking it is gone, then nothing until the next imsg release.
**Phase:** In use. Acceptance closed by Alex; the deletion reconcile is installed and running daily.
**Milestones:** Scaffold ✓ · Reading ✓ · Sending ✓ · Packaging ✓ · Updates ✓ · Cutover ✓ · Acceptance ✓ · Deletion reconcile ✓ · In use (now)

_Rewrite in place on every state change. Why things are the way they are goes in [LOG.md](LOG.md) (append only). Format: the user-level `flight-deck` skill. This repo is public: no names, numbers, hosts or tokens here._

## PLAN
- 1 Build — reading, scrubbing, uplink, sending, status, packaging, updater — done
- 2 Cutover — replace the fork's companion on the Mac — done
- 3 Acceptance — Stage U and Stage S live tests — done (U1–U6, S0–S1; the rest declined by Alex)
- 4 Deletion reconcile — daily `present` run so HomeChat drops deleted texts — done
- 5 In use — nightly updates, Dependabot bumps of imsg — now

## RUNNING NOW
- `ImsgCompanion.app` in `~/Applications` on the MacBook, under launchd, running `225c245` (main's head) since 2026-11-23 03:31 ET, installed by the nightly updater. Checked 11:05 ET: `last_error` null, `watcher_restarts` 0, last uplink 10:11 ET, HomeChat status 2xx at 10:55 ET, not paused, sends on. Full Disk Access and Contacts granted; Automation reads `unknown` until the next preflight or send.
- The updater runs nightly at 03:30. The daily `present` run follows the install: 2026-11-23 result `done`, 92 threads, 1 request, 0 skipped, 0 left out.
- CI (`ci.yml`) on PRs and pushes to `main`; the `automerge` job runs only on Dependabot's PRs.
- Dependabot (swift, daily ~12:35 ET, 3-day cooldown): every run 2026-11-15 to 2026-11-20 failed because a branch named `dependabot` blocked its `dependabot/...` branches. That branch is gone (deleted 2026-11-22). No run since; the next one is unproven.
- The fork app: quit, Login Item off, still installed and paused as the fallback. Its token is revoked, so a rollback needs a fresh one (`cutover.md`).

## QUEUED
- 2026-11-23 ~12:35 ET: check that the scheduled Dependabot run succeeds. If none runs, a no-op change to `.github/dependabot.yml` on `main` forces one.
- Later: the automerge live check (plan Task 12 Step 4) on Dependabot's first imsg bump PR.

## BLOCKED
- None.

## HELD
- The WhatsApp nudge that isn't withdrawn when its flag closes as `unsent` belongs to HomeChat: handed over as homechat-bot#426. Nothing to do here.

## AWAITING Alex
- None.

## DONE
- 2026-11-23 11:20 ET: handed the unsent-nudge finding to `homechat-bot` (issue #426, private repo).
- 2026-11-23 03:31 ET: the updater installed `225c245` (`installed`), and the daily `present` run finished `done` (92 threads).
- Before 2026-11-23 (date not logged): Alex ran the deletion reconcile's Step 7 acceptance himself and reports it worked. No run record or HomeChat readback in this repo.
- 2026-11-16 07:12 ET: PR #23 merged (`8f51f54`) on Alex's yes: the deletion reconcile (`present`), plan Task 14. PR CI green (43858489495).
- 2026-11-16 06:00 ET: the first scheduled updater run (03:30) installed `dfdf468` (U8's install case seen live). Older DONE lines are in LOG ("Moved from STATUS (size trim)", 2026-11-23).

## EVIDENCE
- Live proof: S1, one approved reply sent once to the test contact and received (2026-11-15, `sent`, read-back `confirmed`); U1–U6 uplink cases; scheduled installs on 11-16 and 11-23; daily `present` runs (LOG).
- Not proven live (Alex declined these tests, 2026-11-23, and they are not queued): group, SMS and RCS sends and preflights (S2–S5), a pause from WhatsApp (U7), an unsaved number (U9). `"$BIN" sends off` at the Mac is the proven stop.
- The deletion reconcile's HomeChat side rests on Alex's report, not on a recorded readback.

## STANDING RULES
- Read [AGENTS.md](../AGENTS.md): read-only `chat.db`, sends only after Alex approves the exact text, `sends on` only at the Mac, public repo with no personal data, gate per `.claude/agents/quality-gate.md`.
- Merging to `main` is a deploy: the 03:30 updater installs `main`'s head.

## WHERE THINGS ARE
- Design, contract: `docs/specs/`. Plans: `docs/plans/`. Runbooks: `docs/runbooks/`.
- Rollback: the updater keeps the previous app in `~/Library/Application Support/imsg-companion/previous/`; the fork (`Goldalex98/msgblast-imessage`, frozen) stays installed and paused.
- Older log entries: `.claude/LOG-archive-2026-11-23.md`.
