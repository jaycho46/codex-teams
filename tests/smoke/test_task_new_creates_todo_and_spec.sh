#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-tasks"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

"$CLI" --repo "$REPO" task init >/dev/null

OUT_BASE="$("$CLI" --repo "$REPO" task new T4-320 "Dependency task summary")"
echo "$OUT_BASE"
echo "$OUT_BASE" | grep -q "Added task to TODO board: T4-320"

TMP_TODO="$TMP_DIR/TODO.done.tmp"
awk -F'|' '
  BEGIN { OFS="|" }
  {
    if ($0 ~ /^\|/) {
      id=$2
      gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id == "T4-320") {
        $(NF-1) = " DONE "
      }
    }
    print
  }
' "$REPO/TODO.md" > "$TMP_TODO"
mv "$TMP_TODO" "$REPO/TODO.md"

OUT_NEW="$("$CLI" --repo "$REPO" task new T4-321 --deps T4-320 "New task summary")"
echo "$OUT_NEW"

echo "$OUT_NEW" | grep -q "Added task to TODO board: T4-321"
echo "$OUT_NEW" | grep -q "Created task: id=T4-321"

grep -q "| T4-321 | New task summary | AgentA | T4-320 |  | TODO |" "$REPO/TODO.md"
test -f "$REPO/tasks/specs/T4-321.md"
grep -q "^## Goal$" "$REPO/tasks/specs/T4-321.md"
grep -q "^## In Scope$" "$REPO/tasks/specs/T4-321.md"
grep -q "^## Acceptance Criteria$" "$REPO/tasks/specs/T4-321.md"

OUT_READY="$("$CLI" --repo "$REPO" run start --dry-run --trigger smoke-task-new --max-start 0)"
echo "$OUT_READY"
echo "$OUT_READY" | grep -q "\[DRY-RUN\].*T4-321"
echo "$OUT_READY" | grep -q "Started tasks: 1"

BAD_DEPS_OUT="$TMP_DIR/task-new-bad-deps.out"
if "$CLI" --repo "$REPO" task new T4-322 --deps invalid-dep "bad deps" >"$BAD_DEPS_OUT" 2>&1; then
  echo "invalid deps task creation should fail"
  cat "$BAD_DEPS_OUT"
  exit 1
fi
grep -q "invalid dependency id" "$BAD_DEPS_OUT"

DUP_OUT="$TMP_DIR/task-new-dup.out"
if "$CLI" --repo "$REPO" task new T4-321 --deps T4-320 "duplicate id" >"$DUP_OUT" 2>&1; then
  echo "duplicate task creation should fail"
  cat "$DUP_OUT"
  exit 1
fi
grep -q "Task already exists in TODO board: T4-321" "$DUP_OUT"

echo "task new creates todo and spec smoke test passed"
