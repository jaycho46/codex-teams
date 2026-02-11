# CODEX TEAMS CLI

Unified orchestration CLI for git-worktree based multi-agent execution.

## Entry point

```bash
scripts/codex-teams [--repo <path>] [--state-dir <path>] [--config <path>] <command>
```

## Commands

### Unified status

```bash
scripts/codex-teams status [--json|--tui] [--trigger <label>] [--max-start <n>]
```

Includes scheduler readiness, excluded tasks (with reasons), runtime state counts, and lock snapshots.

- `--tui`: launch interactive status dashboard via `textual` (TTY required).
- TUI shows ready/excluded/runtime/locks by default; task board is fixed at the bottom, hidden initially, and toggled with `t`.
- TUI auto-refreshes scheduler/runtime/task-board state every 2 seconds.
- If `--tui` is used in non-interactive execution (tests/CI), it falls back to text output.
- Install dependency for interactive mode: `python3 -m pip install textual`

### Task domain (state + runtime merged)

```bash
scripts/codex-teams task init [--gitignore <ask|yes|no>]
scripts/codex-teams task lock <agent> <scope> [task_id]
scripts/codex-teams task unlock <agent> <scope>
scripts/codex-teams task heartbeat <agent> <scope>
scripts/codex-teams task update <agent> <task_id> <status> <summary>
scripts/codex-teams task complete <agent> <scope> <task_id> [--summary <text>] [--trigger <label>] [--no-run-start]
scripts/codex-teams task stop (--task <id> | --owner <owner> | --all) [--reason <text>] [--apply]
scripts/codex-teams task cleanup-stale [--apply]
scripts/codex-teams task emergency-stop [--reason <text>] [--apply]
```

`task init` checks whether the state directory path is ignored in `.gitignore`.
- `--gitignore ask` (default): prompt in interactive TTY, print hint in non-interactive runs.
- `--gitignore yes`: append state path automatically when missing.
- `--gitignore no`: skip updates.

### Worktree domain

```bash
scripts/codex-teams worktree create <agent> <task_id> [base_branch] [parent_dir]
scripts/codex-teams worktree start <agent> <scope> <task_id> [base_branch] [parent_dir] [summary]
scripts/codex-teams worktree list
```

### Scheduler domain

```bash
scripts/codex-teams run start [--dry-run] [--launch|--no-launch] [--trigger <label>] [--max-start <n>]
```

Default behavior is start-only (`no-launch`): it creates/locks/updates task state but does not launch codex workers.
Use `--launch` to start detached `codex exec` workers and emit pid metadata under `.state/orchestrator/*.pid`.
If task start/launch fails (for example lock conflicts), scheduler rollback will release owned lock/state and terminate spawned `codex` background pids before cleanup.
Launch workers are started as detached session processes so they survive scheduler command exit.

## Ready task selection behavior

`run start` and `status` derive ready tasks from `TODO.md`, then exclude tasks when any active signal exists:

- `active_worker`: alive pid metadata exists
- `active_lock`: lock-only active record exists
- `owner_busy`: same owner already has an active task
- `deps_not_ready`: dependencies are not satisfied
- `active_signal_conflict`: lock/pid conflict for the same task

This prevents duplicate auto-start when `main` TODO rows are still `TODO` while work continues in subtree worktrees.

## Bootstrap behavior

- Missing config file is auto-created at `.state/orchestrator.toml`.
- Missing `TODO.md` is auto-created with a minimal table template when needed.

## Legacy surface

Legacy command surfaces are intentionally removed:

- `scripts/orch`
- `coord ...`
- `ops ...`
- `run status`

Use `scripts/codex-teams status` and `scripts/codex-teams task ...` instead.

## Testing

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/smoke/test_run_start_dry_run.sh
bash tests/smoke/test_run_start_lock_cleanup.sh
bash tests/smoke/test_run_start_after_done.sh
bash tests/smoke/test_run_start_launch_codex_exec.sh
bash tests/smoke/test_run_start_rollback_kills_codex_on_launch_error.sh
bash tests/smoke/test_run_start_scenario.sh
bash tests/smoke/test_task_init_gitignore.sh
bash tests/smoke/test_task_complete_auto_run_start.sh
bash tests/smoke/test_task_complete_clears_pid_metadata.sh
bash tests/smoke/test_status_tui_fallback.sh
```
