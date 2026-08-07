#!/usr/bin/env bash
# Fail if anything credential-shaped is tracked in this repository.
#
# The patterns in scripts/secret-patterns.txt match the SHAPE of a live secret — a
# three-part JWT, an sb_secret_ key, a database URL that carries a password — rather
# than the bare words. That distinction matters: this repository's own documentation
# discusses "postgres://" and "eyJ" in the open, and it should be able to, while a
# pasted value still stops the build.
#
# Usage: scripts/scan-secrets.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PATTERNS="scripts/secret-patterns.txt"
[[ -f "$PATTERNS" ]] || { echo "FAIL: $PATTERNS is missing — the gate cannot run."; exit 2; }

echo "Scanning $(git ls-files | wc -l | tr -d ' ') tracked files against $(grep -cve '^$' "$PATTERNS") credential patterns."

# The pattern file and this script quote the patterns, so they are excluded from their
# own scan. Lockfiles are excluded: they carry long base64 integrity hashes, never secrets.
if git grep -nIE -f "$PATTERNS" -- \
      ':!scripts/secret-patterns.txt' \
      ':!scripts/scan-secrets.sh' \
      ':!*package-lock.json' \
      ':!*.lock'
then
  echo
  echo "FAIL: credential-shaped string(s) found above. Nothing secret enters this repository."
  exit 1
fi

echo "PASS: no credential-shaped strings in tracked files."
