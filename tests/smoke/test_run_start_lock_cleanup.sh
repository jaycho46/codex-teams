#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-teams"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T9-001 | Ready task | AgentA | - | | TODO |
EOF

# First run should not leave run.lock behind.
OUT1="$($CLI --repo "$REPO" run start --dry-run --trigger smoke-lock-cleanup)"
echo "$OUT1"
echo "$OUT1" | grep -q "Started tasks: 1"

if [[ -d "$REPO/.state/orchestrator/run.lock" ]]; then
  echo "run.lock should be removed after dry-run"
  exit 1
fi

# Inject stale lock and ensure scheduler recovers.
mkdir -p "$REPO/.state/orchestrator/run.lock"
echo "99999999" > "$REPO/.state/orchestrator/run.lock/pid"

OUT2="$($CLI --repo "$REPO" run start --dry-run --trigger smoke-lock-stale)"
echo "$OUT2"

echo "$OUT2" | grep -q "Found stale scheduler lock"
echo "$OUT2" | grep -q "Started tasks: 1"

if [[ -d "$REPO/.state/orchestrator/run.lock" ]]; then
  echo "stale run.lock should be removed after recovery"
  exit 1
fi

echo "run lock cleanup smoke test passed"
