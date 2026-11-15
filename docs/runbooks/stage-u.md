# Stage U: reading and uplink, sends off

Design §6. Run after `cutover.md`, with `sends_enabled` false throughout. Names (`$BIN`, `$UID_GUI`, `$AGENT`,
`$UPDATER`, `$NEW_CFG`) are as in `cutover.md`.

Hard rules:
- No sends: HomeChat refuses every reply while the fork is still linked, and the agent has sends off.
- Nothing writes `chat.db`.
- Every check prints counts, states, times or ROWIDs only, never text, handles or names.
- Test texts go between Alex and his test contacts only.
- HomeChat-side counts come from HomeChat's session, under its own rules.

"Status" below means `"$BIN" status`: the running agent's snapshot, its health mark and the terminal's own readouts.

## U1: launchd starts it at login and after a crash
- **Action:**
  - Alex logs out and back in, or restarts.
  - Then Claude runs `launchctl kill SIGKILL "$UID_GUI/$AGENT"`.
- **Who:** Alex, then Claude.
- **Check:**
  - `launchctl print "$UID_GUI/$AGENT" | grep -E 'state =|pid ='` after the login, and again 15 s after the kill.
  - Alex looks at System Settings → Privacy & Security → Full Disk Access.
- **Pass:**
  - Running after the login.
  - A new pid after the kill.
  - The grant is listed as ImsgCompanion.
  - Status shows `full_disk_access: granted`.

## U2: the first run after cutover carries the cursor
- **Action:** none beyond cutover step 10.
- **Who:** Claude, plus HomeChat's session.
- **Check:**
  - The cursor in `$NEW_CFG` advances past the copied value.
  - HomeChat reports its count of stored messages for the hour around cutover, and how many guids are stored more than once.
  - Claude counts `chat.db` rows in the same ROWID range, read-only and counts only.
- **Pass:**
  - The counts agree, after excluding the kinds the agent skips by rule; HomeChat reports skipped rows too.
  - No guid is stored twice.

## U3: a test-contact text arrives in HomeChat within seconds
- **Action:** a test contact texts Alex.
- **Who:** Alex arranges it.
- **Check:**
  - The status `last_uplink_at`.
  - HomeChat's stored-message count before and after.
- **Pass:** the count rises by 1 within about 5 s of the text arriving on the Mac.

## U4: a question is flagged, and Alex's reply clears it
- **Action:**
  - A test contact asks Alex a question.
  - Alex replies from his phone or the Mac.
- **Who:** Alex.
- **Check:** Alex sees the flag in HomeChat on his phone, then sees it gone.
- **Pass:** flagged once, then cleared by the reply.

## U5: the fork's open checks 5–8
- **Quit-and-reopen catch-up:**
  - Action: Claude runs `launchctl bootout "$UID_GUI/$AGENT"`. The test contact sends 2 texts. Claude bootstraps the agent again.
  - Pass: HomeChat's count rises by 2 after the restart, and by no more.
- **Offline retry:**
  - Action: Alex takes the Mac offline. The test contact sends 1 text. Alex brings the Mac back online.
  - Check: while offline, the status `last_error` is a network code.
  - Pass: after reconnecting, HomeChat's count rises by 1, and `last_error` clears.
- **SSN scrub:**
  - Action: the test contact sends a text containing a made-up SSN-shaped number, such as `123-45-6789`.
  - Check: HomeChat counts stored texts containing `[SSN removed]` and stored texts containing that number.
  - Pass: the first count rises by 1, and the second stays 0.
- **Code skip, both cases:**
  - Action: a code text ("your code is 482913") arrives in a thread Alex has never written in. Then one arrives in a thread he writes in.
  - Check: HomeChat's stored kind and whether text is present, per message.
  - Pass: the first is stored as `skipped` with no text. The second is stored with its text.

## U6: an unsend reaches HomeChat and clears its flag
- **Action:** the test contact sends a question, then unsends it within 2 minutes.
- **Who:** Alex arranges it.
- **Check:**
  - The status `watcher_restarts`, which should not rise.
  - HomeChat's unsent mark and flag state for that guid.
- **Pass:** HomeChat marks the message unsent and its flag is cleared.

## U7: pause and resume from WhatsApp; a local pause holds
- **Action:**
  1. Alex sends HomeChat's pause command.
  2. Alex sends its resume command.
  3. Claude runs `"$BIN" pause`, then Alex sends resume from WhatsApp.
  4. Claude runs `"$BIN" resume`.
- **Who:** Alex and Claude.
- **Check:**
  - The status `paused` after each step. It updates within one send poll, at most about 25 s, plus the 30 s snapshot.
  - HomeChat's status view.
  - HomeChat's command list.
- **Pass:**
  - Paused after 1, and not after 2.
  - Still paused after 3: a remote resume never lifts a local pause.
  - Not paused after 4.
  - HomeChat shows the state each time.
  - No WhatsApp command turns sends on.
- **Known gap, not a bug** (plan "Decided here"):
  - HomeChat's pause lives in memory only. After a restart, the agent may uplink for up to one poll (about 25 s or less) before the pause comes back.
  - With no token set up, a remote pause can't arrive at all.

## U8: the nightly updater, run by launchd
Each case runs the job in launchd's context with `launchctl kickstart "$UID_GUI/$UPDATER"`, which is the context the design says is unproven for signing.

Read the result from:
- the status `last_update`;
- the installed `ImsgCompanionGitSHA`;
- the updater's log in `~/Library/Logs/imsg-companion/`.

Any merged PR gives `main` a new green head.

| Case | Set-up | Pass |
|------|--------|------|
| No update | installed sha equals `main`'s green head | result `none`; app unchanged |
| An update installs | a newer green head on `main` | `installed` with the new sha; health mark for the new version within 180 s; no Keychain prompt (if `codesign` prompts the first time, Alex picks Always Allow once) |
| Paused skips the night | newer green head, agent paused (`"$BIN" pause`) | result `none`; app unchanged; then `"$BIN" resume` |
| Health check fails → rollback | newer green head, and Alex switches the agent's Full Disk Access off first (System Settings), so the new build can't read and writes no `read_ok_at` | `rolled_back`; the previous sha is running again; a second kickstart doesn't retry that sha; then Alex switches Full Disk Access back on |
| HomeChat unreachable | agent stopped (`launchctl bootout "$UID_GUI/$AGENT"`) for over 30 minutes, so the newest successful HomeChat call is older than the updater's 30-minute window | result `none`; app unchanged; the updater starts the stopped agent again first, as it does for any agent left down |
| A send in progress defers | can't be set up with sends off | covered by `UpdaterTests` only; checked live only if a Stage S night happens to have a send in progress. Recorded as test-only, not as passed. |

## U9: Contacts on: an unsaved number isn't flagged and is counted
- **Action:**
  - Alex allows Contacts when `setup` asks (cutover step 5).
  - A number not in his contacts texts him a question.
- **Who:** Alex.
- **Check:**
  - The status `contacts: granted`.
  - HomeChat's twice-daily update.
- **Pass:**
  - No flag for that text.
  - The update's "N texts from unsaved numbers, not checked" includes it.

If status ever shows `last_error: database_replaced` (a restored or replaced `chat.db`), reading stays stopped until Claude runs `"$BIN" reset-cursor` on Alex's say-so. Reading then starts again from 3 days before the replacement, however long ago that was. HomeChat ignores the rows it already holds.

When every case passes, Stage U is done. Record the result in STATUS and LOG: case IDs and pass or fail, no data.
