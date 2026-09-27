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

step "herdr fallback (--herdr-test against a dead socket)"
# Exit 0 = live herdr, 2 = unavailable (expected on most machines), 1 = real
# failure. Only 1 is a problem, so this asserts the exit code explicitly rather
# than letting a non-zero status fail the run.
HERDR_SOCKET=/tmp/terminalfly-no-such.sock "$BIN" --herdr-test
herdr_status=$?
if [ "$herdr_status" -eq 1 ]; then
  echo "FAIL: herdr fallback path reported a real error"
  FAILED=1
elif [ "$herdr_status" -eq 2 ]; then
  echo "herdr fallback OK (herdr not running — expected)"
else
  echo "herdr fallback OK (a live herdr answered)"
fi

step "herdr render path (--herdr-uitest, needs a live herdr)"
# Exercises the full loop in a real window: follow a scratch pane, render it,
# type into it, and fall back on disconnect. Skipped (exit 2) without herdr,
# which is a supported state rather than a failure.
"$BIN" --herdr-uitest
herdr_ui_status=$?
if [ "$herdr_ui_status" -eq 1 ]; then
  echo "FAIL: herdr render path failed"
  FAILED=1
elif [ "$herdr_ui_status" -eq 2 ]; then
  echo "herdr render path SKIPPED (no herdr / no window server)"
else
  echo "herdr render path OK"
fi

step "result"
if [ "$FAILED" -ne 0 ]; then
  echo "FAIL: one or more checks failed"
  exit 1
fi
echo "ALL CHECKS PASSED"
