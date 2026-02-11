Required guardrail skill:
- Use $codex-teams.
- If the skill is unavailable, follow the fallback rules below exactly.

Execution rules:
- Task lifecycle contract: this task was started by run start, and must end via task complete.
- Do not self-start work using task lock/task update/worktree start.
- Do not mark DONE unless task deliverable files were actually added or updated.
- Do not finish with generic summaries such as "task complete" or "done".
- Keep work scoped to the assigned task title and owner scope.
- Do not manually edit lock/pid metadata files.
- Report progress with a specific summary:
  scripts/codex-teams --repo "__WORKTREE_PATH__" --state-dir "__STATE_DIR__" task update "__AGENT__" "__TASK_ID__" IN_PROGRESS "progress update"
- After final verification, mark the task DONE with a specific summary:
  scripts/codex-teams --repo "__WORKTREE_PATH__" --state-dir "__STATE_DIR__" task update "__AGENT__" "__TASK_ID__" DONE "what was delivered"
- Commit message rules:
  - Deliverable commits: <type>: <summary> (__TASK_ID__) where <type> is one of feat|fix|refactor|docs|test|chore
  - Final DONE marker commit: chore: mark __TASK_ID__ done
- Commit everything before task complete:
  git add -A && git commit -m "chore: mark __TASK_ID__ done"
- Use task complete as the final command to perform merge and worktree cleanup.
- When complete, finish with a meaningful summary (or omit --summary to use the default completion log text):
  scripts/codex-teams --repo "__WORKTREE_PATH__" --state-dir "__STATE_DIR__" task complete "__AGENT__" "__SCOPE__" "__TASK_ID__" --summary "what was delivered"
- If task complete hits merge/rebase conflicts, resolve them as much as possible and rerun task complete.
- Only if it still fails after resolution attempts, report BLOCKED:
  scripts/codex-teams --repo "__WORKTREE_PATH__" --state-dir "__STATE_DIR__" task update "__AGENT__" "__TASK_ID__" BLOCKED "merge conflict: <reason>"
