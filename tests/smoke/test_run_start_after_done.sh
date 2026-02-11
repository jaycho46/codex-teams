#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-teams"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

echo "# Scenario Repo" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: initial"

$CLI --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T1-001 | App shell bootstrap | AgentA | - | seed | TODO |
| T1-002 | Domain core service | AgentB | T1-001 | wait T1-001 | TODO |
EOF

git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"

# First scheduler run: only T1-001 should start.
RUN1="$($CLI --repo "$REPO" run start --trigger smoke-after-done-initial)"
echo "$RUN1"

echo "$RUN1" | grep -q "Started tasks: 1"
echo "$RUN1" | grep -q "T1-002 .*reason=deps_not_ready"

WT_A="$TMP_DIR/repo-worktrees/repo-agenta-t1-001"
if [[ ! -d "$WT_A" ]]; then
  echo "missing AgentA worktree: $WT_A"
  exit 1
fi

# Simulate task completion from agent worktree context.
$CLI --repo "$WT_A" --state-dir "$REPO/.state" task update AgentA T1-001 DONE "done in smoke"
$CLI --repo "$WT_A" --state-dir "$REPO/.state" task unlock AgentA app-shell

# Source-of-truth for scheduler is the primary repo TODO board.
# Simulate merge/finish by reflecting T1-001 DONE on main TODO.
TMP_TODO="$TMP_DIR/TODO.main.tmp"
awk -F'|' '
  BEGIN { OFS="|" }
  {
    if ($0 ~ /^\|/) {
      id=$2
      gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id == "T1-001") {
        $(NF-1) = " DONE "
      }
    }
    print
  }
' "$REPO/TODO.md" > "$TMP_TODO"
mv "$TMP_TODO" "$REPO/TODO.md"

# Second scheduler run: dependent T1-002 should start now.
RUN2="$($CLI --repo "$REPO" run start --trigger smoke-after-done-second)"
echo "$RUN2"

echo "$RUN2" | grep -q "Started tasks: 1"
echo "$RUN2" | grep -q "T1-002"

grep -q "| T1-001 | App shell bootstrap | AgentA | - | seed | DONE |" "$REPO/TODO.md"
grep -q "| T1-002 | Domain core service | AgentB | T1-001 | wait T1-001 | TODO |" "$REPO/TODO.md"

STATUS_OUT="$($CLI --repo "$REPO" status --trigger smoke-after-done-second)"
echo "$STATUS_OUT"

echo "$STATUS_OUT" | grep -q "Runtime: total=1 active=1 stale=0"
echo "$STATUS_OUT" | grep -q "\[EXCLUDED\] T1-002 owner=AgentB reason=active_lock source=lock"

echo "run start after done smoke test passed"
