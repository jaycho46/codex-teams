---
name: codex-teams
description: Guardrails for codex-teams worker execution. Use when completing TODO tasks in codex/* worktrees so workers do real file delivery, avoid generic completion commits, and handle merge failures safely.
---

# Codex Teams Guardrails

Apply this skill for tasks executed by `codex-teams run start` workers.

## Hard Rules

1. Lifecycle contract: tasks start via `codex-teams run start` and end via `codex-teams task complete`.
2. Do not self-start work using `task lock`, `task update`, or `worktree start` as a substitute for scheduler start.
3. Do not mark a task `DONE` unless task deliverable files were actually added or updated.
4. Do not finish with generic summaries such as `task complete` or `done`.
5. Keep work scoped to the assigned task title and owner scope.
6. Do not manually edit lock/pid metadata files.
7. Commit all task changes (deliverables + TODO/status updates) before `codex-teams task complete`, then use `task complete` as the last command for merge/worktree cleanup.
8. If completion fails due to merge/rebase conflicts, try to resolve conflicts and re-run `task complete`; report `BLOCKED` only if it remains unresolved.

## Required Workflow

1. Start progress tracking:
   - `scripts/codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" IN_PROGRESS "<specific progress>"`
2. Implement task deliverables in repository files (not only TODO/status metadata).
3. Verify changed files include deliverables:
   - `git status --short`
4. Commit message rules:
   - Deliverable commits: `<type>: <summary> (<task_id>)` where `<type>` is one of `feat|fix|refactor|docs|test|chore`
   - Final DONE marker commit: `chore: mark <task_id> done`
5. After final verification, mark task DONE with a specific summary:
   - `scripts/codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" DONE "<what was delivered>"`
6. Commit everything for the task:
   - `git add -A && git commit -m "chore: mark <task_id> done"`
7. As the final command, use task complete for merge and worktree cleanup (or omit summary to use the default completion log text):
   - `scripts/codex-teams --repo "<worktree>" --state-dir "<state_dir>" task complete "<agent>" "<scope>" "<task_id>" --summary "<what was delivered>"`

## Merge Failure Handling

- `task complete` defaults to `rebase-then-ff`; run it once normally.
- If merge/rebase conflicts occur, resolve conflicts in the worktree as much as possible and run `task complete` again.
- If it still fails after reasonable resolution attempts, do not force status changes.
- Log blocker:
  - `scripts/codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" BLOCKED "merge conflict: <reason>"`
- Leave task for manual resolution.
