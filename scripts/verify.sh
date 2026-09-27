#!/usr/bin/env bash
# Build and verify Terminal Fly, failing loudly.
#
# Exists because `./scripts/build.sh release | tail -10 && echo OK` is a trap:
# the pipeline's exit status is `tail`'s, so a failed build still prints OK.
# This script uses PIPESTATUS and asserts on the artifacts themselves.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

CONFIG="${1:-debug}"
BIN="build/TerminalFly.app/Contents/MacOS/TerminalFly"
FAILED=0

step() { printf '\n=== %s ===\n' "$1"; }

step "build ($CONFIG)"
./scripts/build.sh "$CONFIG"
status=$?
if [ "$status" -ne 0 ]; then
  echo "FATAL: build.sh exited $status"
  exit 1
fi

step "assert binary exists"
if [ ! -x "$BIN" ]; then
  echo "FATAL: $BIN missing or not executable — build.sh reported success but produced nothing"
  exit 1
fi
ls -la "$BIN"

step "assert bundle is complete"
for f in Contents/Info.plist Contents/Resources/AppIcon.icns; do
  if [ ! -e "build/TerminalFly.app/$f" ]; then
    echo "FATAL: build/TerminalFly.app/$f missing"
    FAILED=1
  fi
done
[ "$FAILED" -eq 0 ] && echo "bundle contents OK"

step "logic tests (--test, headless)"
"$BIN" --test || FAILED=1

step "PTY selftest (--selftest)"
"$BIN" --selftest || FAILED=1

step "result"
if [ "$FAILED" -ne 0 ]; then
  echo "FAIL: one or more checks failed"
  exit 1
fi
echo "ALL CHECKS PASSED"
