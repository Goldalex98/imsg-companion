#!/bin/bash
# Builds and signs ImsgCompanion.app (agent design §5.1).
#   scripts/build-app.sh                 signed with the identity in ~/.config/imsg-companion/signing-identity
#   scripts/build-app.sh --verify-only   ad hoc, into a temporary folder: no keychain (CI and the gate)
#   --out DIR                            where the .app goes (default: build/)
# Never prints the identity or the certificate's name.
set -euo pipefail
cd "$(dirname "$0")/.."

verify_only=0
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verify-only) verify_only=1 ;;
    --out) out="${2:?--out needs a folder}"; shift ;;
    *) echo "usage: scripts/build-app.sh [--verify-only] [--out DIR]" >&2; exit 64 ;;
  esac
  shift
done

bundle_id="io.github.goldalex98.imsg-companion"
if [ "$verify_only" = 1 ]; then
  out="${out:-$(mktemp -d)}"
  identity="-"
else
  out="${out:-build}"
  identity_file="$HOME/.config/imsg-companion/signing-identity"
  # The file starts with comment lines; the identity is the first other line.
  identity="$(grep -v '^[[:space:]]*#' "$identity_file" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1 || true)"
  [ -n "$identity" ] || { echo "no signing identity in $identity_file" >&2; exit 1; }
fi

swift build -c release --product imsg-companion
binary="$(swift build -c release --show-bin-path)/imsg-companion"

app="$out/ImsgCompanion.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/imsg-companion"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace ImsgCompanionGitSHA -string "$(git rev-parse --short=12 HEAD)" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"

timestamp=()
[ "$identity" = "-" ] || timestamp=(--timestamp)
codesign --force --options runtime ${timestamp[@]+"${timestamp[@]}"} --entitlements Resources/ImsgCompanion.entitlements \
  --sign "$identity" "$app" 2>/dev/null

codesign --verify --strict "$app"
grep -q "^Identifier=$bundle_id$" <<<"$(codesign -d -v "$app" 2>&1)" || { echo "signed under another identifier" >&2; exit 1; }
if [ "$identity" != "-" ]; then
  # An ad hoc signature's requirement is its cdhash alone, so these checks apply to signed builds.
  requirement="$(codesign -d -r- "$app" 2>&1)"
  grep -q "identifier \"$bundle_id\"" <<<"$requirement" || { echo "designated requirement lacks the bundle ID" >&2; exit 1; }
  # Identifier plus certificate, so grants survive rebuilds; a cdhash requirement would reset them every build.
  grep -q "certificate" <<<"$requirement" || { echo "designated requirement names no certificate" >&2; exit 1; }
  if grep -q "cdhash" <<<"$requirement"; then echo "designated requirement pins a cdhash" >&2; exit 1; fi
fi
entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
for key in com.apple.security.automation.apple-events com.apple.security.personal-information.addressbook; do
  grep -qF "<key>$key</key><true/>" <<<"$entitlements" || { echo "entitlement missing: $key" >&2; exit 1; }
done

echo "built $app ($( [ "$identity" = "-" ] && echo "ad hoc" || echo "signed"))"
