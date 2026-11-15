#!/bin/bash
# Synthetic diffs for scripts/dependabot-diff-ok.sh. Run: scripts/test-dependabot-diff.sh
set -u
cd "$(dirname "$0")/.."
fails=0
check() { # expected-exit name diff
    printf '%s' "$3" | scripts/dependabot-diff-ok.sh > /dev/null 2>&1
    local got=$?
    if [ "$got" -ne "$1" ]; then echo "FAIL: $2 (exit $got, expected $1)"; fails=$((fails + 1)); fi
}
pin='diff --git a/Package.swift b/Package.swift
--- a/Package.swift
+++ b/Package.swift
@@ -9 +9 @@
-    .package(url: "https://github.com/openclaw/imsg.git", exact: "0.21.0"),
+    .package(url: "https://github.com/openclaw/imsg.git", exact: "0.22.1"),
'
resolved='diff --git a/Package.resolved b/Package.resolved
--- a/Package.resolved
+++ b/Package.resolved
@@ -5,2 +5,2 @@
-        "revision" : "1bc0679",
-        "version" : "0.21.0"
+        "revision" : "abcdef0",
+        "version" : "0.22.1"
'
check 0 "pin bump" "$pin"
check 0 "pin bump plus Package.resolved" "$pin$resolved"
check 0 "Package.resolved only" "$resolved"
check 1 "empty diff" ""
check 1 "another file" "$pin"'diff --git a/Sources/x.swift b/Sources/x.swift
--- a/Sources/x.swift
+++ b/Sources/x.swift
@@ -1 +1 @@
-a
+b
'
check 1 "another Package.swift line" 'diff --git a/Package.swift b/Package.swift
--- a/Package.swift
+++ b/Package.swift
@@ -12 +12 @@
-    .target(name: "CompanionCore"),
+    .target(name: "CompanionCore", swiftSettings: [.unsafeFlags(["-x"])]),
'
check 1 "pin moved to another URL" 'diff --git a/Package.swift b/Package.swift
--- a/Package.swift
+++ b/Package.swift
@@ -9 +9 @@
-    .package(url: "https://github.com/openclaw/imsg.git", exact: "0.21.0"),
+    .package(url: "https://github.com/someone/imsg.git", exact: "0.22.1"),
'
check 1 "pin to a branch" 'diff --git a/Package.swift b/Package.swift
--- a/Package.swift
+++ b/Package.swift
@@ -9 +9 @@
-    .package(url: "https://github.com/openclaw/imsg.git", exact: "0.21.0"),
+    .package(url: "https://github.com/openclaw/imsg.git", branch: "main"),
'
check 1 "file renamed into Package.swift" 'diff --git a/evil.swift b/Package.swift
similarity index 100%
rename from evil.swift
rename to Package.swift
'
[ "$fails" -eq 0 ] && echo "all dependabot diff checks passed"
exit "$fails"
