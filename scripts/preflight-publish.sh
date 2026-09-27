#!/usr/bin/env bash
# Pre-flight scan before publishing the repo publicly.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

echo "=== 1. secret patterns ==="
grep -rInE "(gho_|ghp_|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY)" \
  --exclude-dir=build --exclude-dir=.git --exclude-dir=vendor --exclude="$SELF" . 2>/dev/null | head -20
echo "(empty above = clean)"

echo
echo "=== 2. hardcoded absolute home paths ==="
grep -rIn "$HOME" \
  --exclude-dir=build --exclude-dir=.git --exclude-dir=vendor --exclude="$SELF" . 2>/dev/null | head -10
echo "(empty above = clean)"

echo
echo "=== 3. git history secrets (if any commits exist) ==="
git log --oneline 2>/dev/null | head -3 || echo "(no commits yet)"

echo
echo "=== 4. files staged ==="
git status --short

echo
echo "=== 5. total tracked size estimate ==="
git add -A >/dev/null 2>&1
git diff --cached --stat | tail -3
