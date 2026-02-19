<h1>codex-tasks</h1>

<p align="center">
  <img src="./docs/logo.svg" alt="codex-tasks logo" width="540" />
</p>

<p align="center">
  <strong>Orchestration SKILL and CLI for parallel Codex workers</strong>
</p>

<p align="center">
  <a href="#best-practice-recommended">Best Practice</a> |
  <a href="#install-cli">Install CLI</a> |
  <a href="#quickstart-app--terminal-flow">Quickstart</a> |
  <a href="#docs">Docs</a>
</p>

<p align="center">
  <img alt="codex skill" src="https://img.shields.io/badge/Codex%20Skill-0f766e?style=for-the-badge">
  <img alt="codex skill" src="https://img.shields.io/badge/macOS-000000?logoColor=F0F0F0&style=for-the-badge">
  <img alt="license" src="https://img.shields.io/github/license/jaycho46/codex-teams?style=for-the-badge">
  <img alt="version" src="https://img.shields.io/github/v/release/jaycho46/codex-teams?style=for-the-badge">
  <img alt="tests" src="https://img.shields.io/github/actions/workflow/status/jaycho46/codex-teams/ci.yml?branch=main&style=for-the-badge&label=tests">
</p>

## Best Practice (Recommended)

Use a split workflow:

1. Codex app + `$codex-tasks` skill: create/refine TODO tasks and task specs.
2. Terminal + `codex-tasks`: start scheduler, monitor runtime, and control operations.

This keeps planning in the app and orchestration in the terminal.

## Install CLI

```bash
curl -fsSL https://raw.githubusercontent.com/jaycho46/codex-tasks/main/scripts/install-codex-tasks.sh | bash
```

Default install paths:

- payload: `~/.local/share/codex-tasks/<version>/scripts`
- launcher: `~/.local/bin/codex-tasks`

## Install Codex Skill

In Codex app, run `$skill-installer` with:

```text
$skill-installer Install skill from GitHub:
- repo: jaycho46/codex-tasks
- path: skills/.curated/codex-tasks
```

Skill file in this repo: `skills/.curated/codex-tasks/SKILL.md`

## Requirements

- `git`
- `python3`
- `codex` CLI (required for worker launch; optional with `run start --no-launch`)
- `tmux` (required only for default launch mode)
- optional TUI dependency:

```bash
python3 -m pip install textual
```

## Quickstart: App + Terminal Flow

### 1) In Codex app, create tasks with skill guardrails

Codex app prompt example:

```text
$codex-tasks
Plan authentication work and create an executable TODO list with task specs.
Keep tasks small, add dependencies where needed, and summarize what you changed.
```

### 2) In terminal, commit planning artifacts (`TODO.md` + task specs)

Commit planning files so worker worktrees can pick them up.

Commit prompt example:

```text
Commit planning files so worker worktrees can pick them up.
```

or

```bash
git add TODO.md tasks/specs/*.md
git commit -m "docs: add task plan and specs"
```

### 3) In terminal, orchestrate execution

```bash
# open live dashboard (default command)
codex-tasks
```

Then press `Ctrl+R` in the dashboard to run scheduler start.

Dashboard operations:

- In the Task table, select a task and press `Enter` to open a spec-detail overlay.
- In the Running Agents table, select (or click) an agent row to open a session overlay and inspect live execution progress.
- If execution is going wrong, press `Ctrl+E` to stop all active tasks. This runs emergency stop (`task stop --all --apply`), cleans runtime state, and rolls affected tasks back to `TODO`.

## How It Works

`codex-tasks` uses `TODO.md` as a dependency-aware queue and applies a strict task lifecycle.

1. Queue build (`TODO.md` -> ready/excluded)

- Scheduler scans `TODO.md` and evaluates only rows with `TODO` status.
- A task is added to the ready queue only when:
  - owner/scope mapping exists
  - no active worker, active lock, or conflicting runtime signal exists
  - owner is not already busy
  - dependencies are ready
  - spec file exists and is valid (`tasks/specs/<task_id>.md`)
- Non-ready tasks stay visible as excluded with reasons such as `owner_busy`, `deps_not_ready`, `missing_task_spec`, or `invalid_task_spec`.

```mermaid
flowchart LR
  A["TODO.md row (status=TODO)"] --> B{"Owner/scope mapped?"}
  B -- "No" --> X["Excluded (unmapped owner)"]
  B -- "Yes" --> C{"Active worker/lock/conflict?"}
  C -- "Yes" --> E["Excluded (active_worker / active_lock / active_signal_conflict)"]
  C -- "No" --> D{"Owner already busy?"}
  D -- "Yes" --> F["Excluded (owner_busy)"]
  D -- "No" --> G{"Spec exists + valid?"}
  G -- "No" --> H["Excluded (missing_task_spec / invalid_task_spec)"]
  G -- "Yes" --> I{"Dependencies ready?"}
  I -- "No" --> J["Excluded (deps_not_ready)"]
  I -- "Yes" --> K["Ready Queue"]
```

2. Start phase (`run start`)

- Scheduler acquires a run lock to avoid concurrent starts.
- For each ready task, it creates/starts a dedicated worktree + branch.
- It writes runtime metadata (lock + pid) and launches a worker (`codex exec`, default backend: `tmux`).

3. Runtime phase

- Workers execute inside their task worktrees and report progress/status.
- Dashboard shows the ready queue, running workers, and excluded reasons in one view.

4. Auto cleanup / recovery

- If a worker exits unexpectedly, auto-cleanup runs for that task.
- It removes stale runtime state (pid/lock/worktree/branch) and rolls the task back to `TODO` unless it is already `DONE`.

5. Completion phase (`task complete`)

- Completion is accepted only when the task is `DONE`, tracked changes are committed, and lock owner/scope match.
- `task complete` merges into base branch (default `rebase-then-ff`), clears runtime metadata, removes worktree/branch, and automatically runs the next scheduler start by default (disable with `--no-run-start`).

Continuous loop view:

```mermaid
flowchart LR
  subgraph MAIN["Main execution loop"]
    A["Plan tasks in TODO.md + specs"] --> B["Run scheduler (Ctrl+R or codex-tasks run start)"]
    B --> C["Ready queue selection"]
    C --> D["Worker runs in task worktree"]
    D --> E{"Task outcome"}
    E -- "DONE + committed" --> F["task complete (merge + cleanup)"]
    F -->|"auto run start"| B
  end

  E -- "Worker exited/failure" --> G["Outside loop: auto cleanup"]
  G --> H["Remove pid/lock/worktree/branch"]
  H --> I["Rollback task status to TODO (unless DONE)"]
```

Failed tasks re-enter the queue on the next scheduler run.

## Docs

- Task authoring: [`docs/task-authoring-with-scaffold-specs.md`](docs/task-authoring-with-scaffold-specs.md)
- Worker rules: [`scripts/prompts/codex-worker-rules.md`](scripts/prompts/codex-worker-rules.md)

## License

MIT. See `LICENSE`.
