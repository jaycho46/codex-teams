---
name: codex-teams-task-guardrails
description: Guardrails for codex-teams worker execution. Use when completing TODO tasks in codex/* worktrees so workers do real file delivery, avoid generic completion commits, and handle merge failures safely.
---

# Codex Teams Task Guardrails

Apply this skill for tasks executed by `codex-teams run start` workers.

## Hard Rules

1. Lifecycle contract: tasks start via `codex-teams run start` and end via `codex-teams task complete`.
2. Do not self-start work using `task lock`, `task update`, or `worktree start` as a substitute for scheduler start.
3. Do not mark a task `DONE` unless task deliverable files were actually created or changed.
4. Do not finish with generic summaries such as `task complete`, `done`, or `완료`.
5. Keep work scoped to the assigned task title and owner scope.
6. Do not manually edit lock/pid metadata files.
7. If completion fails due to merge/rebase conflicts, stop and report `BLOCKED` with a concrete reason.

## Required Workflow

1. Start progress tracking:
   - `scripts/codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" IN_PROGRESS "<specific progress>"`
2. Implement task deliverables in repository files (not only TODO/status metadata).
3. Verify changed files include deliverables:
   - `git status --short`
4. Complete task with a meaningful summary (or omit summary to fallback to task title):
   - `scripts/codex-teams --repo "<worktree>" --state-dir "<state_dir>" task complete "<agent>" "<scope>" "<task_id>" --summary "<what was delivered>"`

## Merge Failure Handling

- `task complete` defaults to `rebase-then-ff`; run it once normally.
- If it still fails, do not force status changes.
- Log blocker:
  - `scripts/codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" BLOCKED "merge conflict: <reason>"`
- Leave task for manual resolution.
