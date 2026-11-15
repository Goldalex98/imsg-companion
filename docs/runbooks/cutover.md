# Cutover: from the fork app to the agent

Follows design §5.7. Hard rules throughout:
- No sends.
- Nothing writes `chat.db` or marks a message read.
- Real-data checks print counts and states only.
- Alex makes every System Settings change and every Login Item change.

Names used below (copy as written):

```sh
UID_GUI="gui/$(id -u)"
AGENT=io.github.goldalex98.imsg-companion
UPDATER=io.github.goldalex98.imsg-companion.updater
BIN="$HOME/Applications/ImsgCompanion.app/Contents/MacOS/imsg-companion"
NEW_CFG="$HOME/Library/Application Support/imsg-companion/companion.json"
FORK_CFG="$HOME/Library/Application Support/msgblast-iMessage/companion.json"
```

## Before starting

| # | Step | Who | Check | Pass |
|---|------|-----|-------|------|
| 0a | Install `main`'s green head with `scripts/install.sh` (the installed build may predate `update`). | Claude | `codesign -dvv "$HOME/Applications/ImsgCompanion.app" 2>&1 \| grep -c '^Authority=Apple Development'` (`-dv` prints no Authority lines) and `/usr/libexec/PlistBuddy -c 'Print :ImsgCompanionGitSHA' .../Info.plist` | `1`, and the sha equals `main`'s head |
| 0b | Grant Full Disk Access to `~/Applications/ImsgCompanion.app`. | Alex (System Settings) | `"$BIN" status` → the running agent's snapshot | `full_disk_access: granted` |

## Order

| # | Step | Who | Check (counts only) | Pass |
|---|------|-----|---------------------|------|
| 1 | HomeChat deploys its §7 changes. | HomeChat's session, by its runbook | HomeChat's own post-deploy check | deployed and healthy |
| 2 | Confirm HomeChat holds no unfinished sends. | HomeChat's session | count of sends not in a final state | `0` |
| 3 | Issue a device token for the new Mac. | Alex, via HomeChat | Alex has the token to paste in step 5. It never goes into chat, logs or this repo. | token issued |
| 4 | Pause the agent locally and stop both jobs: `"$BIN" pause`, then `launchctl bootout "$UID_GUI/$UPDATER"` and `launchctl bootout "$UID_GUI/$AGENT"`. The updater restarts a stopped agent, so it stays out until step 10. | Claude | `launchctl print` for each | "could not find service" for both |
| 5 | `"$BIN" setup <HomeChat URL>`. Alex pastes the token at the prompt, and the Contacts prompt appears. | Alex types the token; Claude runs the command | the command's `saved: host …, device …, token saved` line | token saved |
| 6 | Start the agent, still paused: `launchctl bootstrap "$UID_GUI" "$HOME/Library/LaunchAgents/$AGENT.plist"`. A paused agent reads nothing and uplinks no messages. Status posts still go out. | Claude | wait 60 s, then `"$BIN" status`: the health mark's `homechat_ok_at` and the snapshot's `last_error` | `homechat_ok_at` set, `last_error` null. **This is the §7 proof:** `POST /imsg/status` answered 2xx (the contract's 204) with the new token. A 404 or 401 here means stop and return to step 1. |
| 7 | Quit the fork app and switch off its Login Item. It stays installed, paused, as the fallback. | Alex | `"$BIN" status`: the terminal's own `fork_running` readout (checked by the fork's bundle ID) | `false` |
| 8 | Stop the agent again: `launchctl bootout "$UID_GUI/$AGENT"`. | Claude | as step 4 | not found |
| 9 | Copy the fork's cursor into the new config (script below). | Claude | the script's output: two integers and `written` | the new cursor equals the fork's |
| 10 | Resume and start both: `"$BIN" resume`, then `launchctl bootstrap "$UID_GUI" "$HOME/Library/LaunchAgents/$AGENT.plist"` and the same for `$UPDATER.plist`. | Claude | after 60 s, `"$BIN" status` (snapshot and health mark), and `python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cursor"))' "$NEW_CFG"` | `read_ok_at` set after the start, `paused` false, `last_error` null, `fork_running` false, cursor ≥ the copied value |
| 11 | Stage U begins (`stage-u.md`). | Alex and Claude | | |

Step 9, run only with the agent and the fork app both stopped. It prints the two cursors (ROWIDs, not message data) and nothing else.

```sh
python3 - "$FORK_CFG" "$NEW_CFG" <<'PY'
import json, os, sys, tempfile
fork, new = sys.argv[1], sys.argv[2]
cursor = json.load(open(fork)).get("cursor")
assert isinstance(cursor, int), "the fork has no cursor"
cfg = json.load(open(new))
print("fork cursor", cursor, "new cursor before", cfg.get("cursor"))
cfg["cursor"] = cursor
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(new))
with os.fdopen(fd, "w") as f: json.dump(cfg, f, indent=2, sort_keys=True)
os.replace(tmp, new)
print("written")
PY
```

Why copying the cursor is safe:
- Both cursors are the last ROWID scanned, so nothing is missed.
- HomeChat stores by `guid` with `INSERT OR IGNORE`, so a cursor a little behind only re-posts rows it ignores.
- The first-run window is not used.
- The fork's send ledger is not copied: it holds 0 records, and HomeChat binds each send to a device.

## Before Stage S

- **Revoke the fork's token in HomeChat** (Alex, via HomeChat). HomeChat refuses every send while more than one Mac is linked, so until this is done every reply is refused, which is expected throughout Stage U.
- After the revoke, rolling back to the fork needs a fresh fork token (HomeChat's runbook).

## Rollback

| # | Step | Who |
|---|------|-----|
| 1 | Stop both jobs, the updater first: `launchctl bootout "$UID_GUI/$UPDATER"`, then `launchctl bootout "$UID_GUI/$AGENT"`. Both are needed, because the nightly updater starts a stopped agent again. | Claude |
| 2 | Copy the agent's cursor back into the fork's config: the step 9 script with its two arguments swapped. | Claude |
| 3 | If the fork's token was revoked, issue it a fresh one (HomeChat's runbook). | Alex, via HomeChat |
| 4 | Open the fork app, unpause it, and turn its Login Item back on. | Alex |

## After acceptance (each with Alex's yes)

- Alex removes the fork app's grants in System Settings.
- Remove the fork's Keychain item and Login Item.
- Archive `Goldalex98/msgblast-imessage` on GitHub.
- Uninstall the Homebrew `imsg` binary. It plays no part in the agent.
