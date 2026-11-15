#!/bin/bash
# Installs a built ImsgCompanion.app to ~/Applications and (re)loads its two launchd agents. It never turns sends
# on and never runs setup: a fresh install idles in "not set up".
#   scripts/install.sh [path/to/ImsgCompanion.app]   (default: build/ImsgCompanion.app)
set -euo pipefail
cd "$(dirname "$0")/.."

source_app="${1:-build/ImsgCompanion.app}"
dest="$HOME/Applications/ImsgCompanion.app"
domain="gui/$(id -u)"
agents="$HOME/Library/LaunchAgents"

codesign --verify --strict "$source_app"

for label in io.github.goldalex98.imsg-companion io.github.goldalex98.imsg-companion.updater; do
  # bootout sends SIGTERM; the agent finishes an in-flight send first (ExitTimeOut 120).
  launchctl bootout "$domain/$label" 2>/dev/null || true
  # bootout can return before the process has exited; bootstrapping then fails with error 5.
  for _ in $(seq 1 130); do
    launchctl print "$domain/$label" >/dev/null 2>&1 || break
    sleep 1
  done
  if launchctl print "$domain/$label" >/dev/null 2>&1; then echo "$label didn't stop" >&2; exit 1; fi
done

mkdir -p "$HOME/Applications" "$agents" "$HOME/Library/Logs/imsg-companion"
rm -rf "$dest"
ditto "$source_app" "$dest"
codesign --verify --strict "$dest"

for name in agent updater; do
  label="io.github.goldalex98.imsg-companion"
  [ "$name" = updater ] && label="$label.updater"
  plist="$agents/$label.plist"
  sed "s|__HOME__|$HOME|g" "launchd/$name.plist.template" > "$plist"
  plutil -lint -s "$plist"
  launchctl bootstrap "$domain" "$plist"
done
echo "installed $dest; agents loaded"
