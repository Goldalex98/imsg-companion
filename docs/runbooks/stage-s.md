# Stage S: sends on, to test contacts

Design §6. Run only after Stage U passes.

**Every real send in this stage needs Alex's typed yes first, and goes to a test contact only.** Claude never approves, queues or retries a send. An `ambiguous` or uncertain result is never retried. Names are as in `cutover.md`.

## Before S0
1. **Revoke the fork's token in HomeChat** (Alex, via HomeChat). Until then, HomeChat refuses every send.
2. **Turn sends on:** Claude runs `"$BIN" sends on`, only on Alex's say-so. The status should show `sends_enabled: true`. Sends can only be turned on at the Mac.
3. **Find each test thread's chat ROWID:** HomeChat doesn't store it (its threads are keyed by chat guid). Claude reads it on the Mac, read-only and integers only: `sqlite3 -readonly "file:$HOME/Library/Messages/chat.db?mode=ro" "SELECT chat_id FROM chat_message_join WHERE message_id = <a message ROWID HomeChat gives>"`. A contact reached at two addresses has two chats, so preflight the one the test question actually arrives in.

## S0: preflight on each chat kind; Automation shows under the agent
- **Action:** Claude runs `"$BIN" preflight <chat ROWID>` for each of these, if one exists:
  - an iMessage 1:1;
  - an `any;+;` group;
  - an SMS 1:1;
  - an RCS 1:1.
- **Who:** Claude. Alex clicks Allow on the first Automation prompt.
- **Check:**
  - The status shows `preflight-result.json` for each chat.
  - The status shows `automation_messages`.
  - Alex looks at System Settings → Privacy & Security → Automation.
- **Pass:**
  - Each preflight is `ready`, or refused with a code that is explained.
  - The first preflight raises the Automation prompt and comes back `refused` with -1712 (AppleEvent timeout) while the prompt waits. After Allow, run it again.
  - Automation → Messages is listed under ImsgCompanion.
  - `automation_messages: granted`.
  - Nothing is sent: preflight never dispatches.

## S1–S5

For every case, **Alex's typed yes first, test contact only.** Alex approves the exact text in HomeChat, and the agent sends only that text.

Every case also checks:
- the send result's `sent_service`;
- that the ledger record under `~/Library/Application Support/imsg-companion/companion-sends/` has no text field. Check its keys only, e.g. `python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))))' <record>`.

| Case | Action (Alex) | Check | Pass |
|------|---------------|-------|------|
| S1 | approve a reply in an iMessage 1:1 with a test contact | send result; the test contact confirms receipt | `sent`, `sent_service` `iMessage`, received **once** |
| S2 | approve a reply in an SMS-labelled iMessage group of test contacts | send result; receipt | `sent` with the read-back's `sent_service`; received once by each member |
| S3 | approve an SMS 1:1 reply that contains an accent and an emoji | send result; the test contact confirms that the characters arrived intact | `sent`, `sent_service` `SMS`; text arrives exactly as approved |
| S4 | approve a reply in a test group, then change the group's participants before it sends | send result | refused with the changed-participants code; nothing sent |
| S5 | approve a reply and let the approval expire before the Mac fetches it (Alex sets the wait with HomeChat's expiry rule) | send result | refused as expired; nothing sent |

Afterwards, sends stay on or go off as Alex decides (`"$BIN" sends off`).

**Not covered, so still unproven:** true MMS groups and RCS groups, unless a test group of that kind exists. Also late delivery while the iPhone is offline: it can't be cancelled, and it is reported as whatever the read-back shows.
