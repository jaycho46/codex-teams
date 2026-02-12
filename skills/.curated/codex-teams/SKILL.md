---
name: codex-teams
description: Guardrails for codex-teams worker execution. Use when completing TODO tasks in codex/* worktrees so workers do real file delivery, avoid generic completion commits, and handle merge failures safely.
---

# Codex Teams Guardrails

Apply this skill for tasks executed by `codex-teams run start` workers.

## CLI Bootstrap

Before running any workflow command, ensure the `codex-teams` CLI is installed:

1. Check availability:
   - `command -v codex-teams >/dev/null 2>&1`
2. If missing, install via the canonical installer:
   - `REPO="${CODEX_TEAMS_REPO:-jaycho46/codex-teams}"; curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/install-codex-teams.sh" | bash -s -- --repo "$REPO" --version "${CODEX_TEAMS_VERSION:-latest}" --force`
3. If still not found because of PATH:
   - `export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"`
4. If network or write sandbox blocks install, request escalation and rerun the installer command.

## Hard Rules

1. Lifecycle contract: tasks start via `codex-teams run start` and end via `codex-teams task complete`.
2. Do not self-start work using `task lock`, `task update`, or `worktree start` as a substitute for scheduler start.
3. Do not mark a task `DONE` unless task deliverable files were actually added or updated.
4. Do not finish with generic summaries such as `task complete` or `done`.
5. Keep work scoped to the assigned task title and owner scope.
6. Do not manually edit lock/pid metadata files.
7. Commit all task changes (deliverables + TODO/status updates) before `codex-teams task complete`, then use `task complete` as the last command for merge/worktree cleanup.
8. If completion fails due to merge/rebase conflicts, try to resolve conflicts and re-run `task complete`; report `BLOCKED` only if it remains unresolved.
9. For newly requested tasks, create them with `codex-teams task new <task_id> [--deps <task_id[,task_id...]>] <summary>` and fully populate the generated spec before scheduling.

## Task Authoring (New Task)

When asked to create a new task, use this flow:

1. Create task row + spec template in one command:
   - `codex-teams task new <task_id> [--deps <task_id[,task_id...]>] <summary>`
   - If the task has prerequisites, pass prerequisite task ids with `--deps` (for example: `--deps T2-100,T2-099`).
2. Confirm the generated spec file exists:
   - `tasks/specs/<task_id>.md`
3. Fill the generated form completely (do not leave template placeholders):
   - Keep exact headings: `## Goal`, `## In Scope`, `## Acceptance Criteria`
   - Add concrete test/validation details in `## Acceptance Criteria`:
     - which tests or checks must run
     - exact command(s) to run
     - expected pass condition/output
4. Only start scheduling after spec content is complete:
   - `codex-teams run start --dry-run`

## Required Workflow

1. Ensure `codex-teams` command is available (run CLI bootstrap above if needed).
2. Start progress tracking:
   - `codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" IN_PROGRESS "<specific progress>"`
3. Implement task deliverables in repository files (not only TODO/status metadata).
4. Verify changed files include deliverables:
   - `git status --short`
5. Commit message rules:
   - Deliverable commits: `<type>: <summary> (<task_id>)` where `<type>` is one of `feat|fix|refactor|docs|test|chore`
   - Final DONE marker commit: `chore: mark <task_id> done`
6. After final verification, mark task DONE with a specific summary:
   - `codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" DONE "<what was delivered>"`
7. Commit everything for the task:
   - `git add -A && git commit -m "chore: mark <task_id> done"`
8. As the final command, use task complete for merge and worktree cleanup (or omit summary to use the default completion log text):
   - `codex-teams --repo "<worktree>" --state-dir "<state_dir>" task complete "<agent>" "<scope>" "<task_id>" --summary "<what was delivered>"`

## Merge Failure Handling

- `task complete` defaults to `rebase-then-ff`; run it once normally.
- If merge/rebase conflicts occur, resolve conflicts in the worktree as much as possible and run `task complete` again.
- If it still fails after reasonable resolution attempts, do not force status changes.
- Log blocker:
  - `codex-teams --repo "<worktree>" --state-dir "<state_dir>" task update "<agent>" "<task_id>" BLOCKED "merge conflict: <reason>"`
- Leave task for manual resolution.
