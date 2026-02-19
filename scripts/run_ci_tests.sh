#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Ensure git commits in smoke tests work in CI environments that do not
# define a default git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Codex CI}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-codex-ci@example.com}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

python3 -m unittest discover -s tests -p 'test_*.py'

smoke_tests=(
  tests/smoke/test_run_start_dry_run.sh
  tests/smoke/test_run_start_lock_cleanup.sh
  tests/smoke/test_run_start_requires_task_spec.sh
  tests/smoke/test_run_start_after_done.sh
  tests/smoke/test_run_start_launch_codex_exec.sh
  tests/smoke/test_run_start_tmux_missing_policy.sh
  tests/smoke/test_run_start_auto_cleanup_on_exit.sh
  tests/smoke/test_run_start_rollback_kills_codex_on_launch_error.sh
  tests/smoke/test_run_start_orphan_worktree_path_recovery.sh
  tests/smoke/test_run_start_scenario.sh
  tests/smoke/test_task_new_creates_todo_and_spec.sh
  tests/smoke/test_task_init_gitignore.sh
  tests/smoke/test_task_init_gitignore_symlink_state_dir.sh
  tests/smoke/test_task_update_respects_schema_status_col.sh
  tests/smoke/test_task_complete_auto_run_start.sh
  tests/smoke/test_task_complete_clears_pid_metadata.sh
  tests/smoke/test_task_complete_commit_summary_fallback.sh
  tests/smoke/test_task_complete_auto_rebase_merge.sh
  tests/smoke/test_auto_cleanup_done_guard.sh
  tests/smoke/test_status_tui_fallback.sh
)

for smoke_test in "${smoke_tests[@]}"; do
  bash "$smoke_test"
done
