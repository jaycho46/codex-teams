# CODEX TEAMS CLI

Unified orchestration CLI for git-worktree based multi-agent execution.

## Entry point

```bash
scripts/codex-teams [--repo <path>] [--coord-dir <path>] [--config <path>] <command>
```

## Commands

### Unified status

```bash
scripts/codex-teams status [--json] [--trigger <label>] [--max-start <n>]
```

Includes scheduler readiness, excluded tasks (with reasons), runtime state counts, and lock snapshots.

### Task domain (state + runtime merged)

```bash
scripts/codex-teams task init
scripts/codex-teams task lock <agent> <scope> [task_id]
scripts/codex-teams task unlock <agent> <scope>
scripts/codex-teams task heartbeat <agent> <scope>
scripts/codex-teams task update <agent> <task_id> <status> <summary>
scripts/codex-teams task stop (--task <id> | --owner <owner> | --all) [--reason <text>] [--apply]
scripts/codex-teams task cleanup-stale [--apply]
scripts/codex-teams task emergency-stop [--reason <text>] [--apply]
```

### Worktree domain

```bash
scripts/codex-teams worktree create <agent> <task_id> [base_branch] [parent_dir]
scripts/codex-teams worktree start <agent> <scope> <task_id> [base_branch] [parent_dir] [summary]
scripts/codex-teams worktree list
```

### Scheduler domain

```bash
scripts/codex-teams run start [--dry-run] [--no-launch] [--trigger <label>] [--max-start <n>]
```

MVP behavior is start-only (`no-launch` default): it creates/locks/updates task state but does not launch codex workers.

## Ready task selection behavior

`run start` and `status` derive ready tasks from `TODO.md`, then exclude tasks when any active signal exists:

- `active_worker`: alive pid metadata exists
- `active_lock`: lock-only active record exists
- `owner_busy`: same owner already has an active task
- `deps_not_ready`: dependencies are not satisfied
- `active_signal_conflict`: lock/pid conflict for the same task

This prevents duplicate auto-start when `main` TODO rows are still `TODO` while work continues in subtree worktrees.

## Bootstrap behavior

- Missing config file is auto-created at `.coord/orchestrator.toml`.
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
```
