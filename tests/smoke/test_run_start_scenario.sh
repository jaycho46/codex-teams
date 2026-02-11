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

cat > "$REPO/README.md" <<'EOF'
# Scenario Repo
EOF

git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: initial"

$CLI --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T1-001 | App shell bootstrap | AgentA | - | seed | TODO |
| T1-002 | Domain core service | AgentB | T1-001 | blocked by T1-001 | TODO |
| T1-003 | Provider integration | AgentC | - | seed | TODO |
| T1-004 | UI popover polish | AgentD | T1-003 | blocked by T1-003 | TODO |
| T1-005 | CI release pipeline | AgentE | - | seed | TODO |
EOF

git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"

RUN_OUT="$($CLI --repo "$REPO" run start --trigger smoke-scenario)"
echo "$RUN_OUT"

echo "$RUN_OUT" | grep -q "Started tasks: 3"

echo "$RUN_OUT" | grep -q "Post-start unified status"

echo "$RUN_OUT" | grep -q "Coordination: locks=3"

STATUS_OUT="$($CLI --repo "$REPO" status --trigger smoke-scenario)"
echo "$STATUS_OUT"

echo "$STATUS_OUT" | grep -q "Scheduler: ready=0 excluded=5"
echo "$STATUS_OUT" | grep -q "Runtime: total=3 active=3 stale=0"
echo "$STATUS_OUT" | grep -q "Coordination: locks=3"

WT_COUNT="$($CLI --repo "$REPO" worktree list | wc -l | tr -d ' ')"
if [[ "$WT_COUNT" != "4" ]]; then
  echo "unexpected worktree count: $WT_COUNT (expected 4)"
  exit 1
fi

echo "run start scenario smoke test passed"
