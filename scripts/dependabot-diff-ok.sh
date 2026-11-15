#!/bin/bash
# Reads a PR's unified diff on stdin; exits 0 only for a dependency bump CI may merge by itself (design §5.6): it
# touches only Package.swift and Package.resolved, and in Package.swift it changes only the imsg exact-tag pin line.
set -euo pipefail
awk '
    BEGIN { files = 0; bad = 0 }
    /^diff --git / {
        files++
        a = substr($3, 3); b = substr($4, 3); file = b
        if (a != b || (b != "Package.swift" && b != "Package.resolved")) { print "not allowed: " b; bad = 1 }
        next
    }
    /^(rename|copy) (from|to) / { print "rename or copy"; bad = 1; next }
    /^(\+\+\+|---) / { next }
    /^[+-]/ && file == "Package.swift" {
        if ($0 !~ /^[+-]    \.package\(url: "https:\/\/github\.com\/openclaw\/imsg\.git", exact: "[0-9]+\.[0-9]+\.[0-9]+"\),$/) {
            print "Package.swift: a change other than the imsg pin"; bad = 1
        }
    }
    END { if (files == 0) { print "empty diff"; bad = 1 }; exit bad }
'
