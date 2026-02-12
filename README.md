# codex-teams

![codex-teams](https://github.com/user-attachments/assets/f3addb72-077b-4515-b123-3f7d14352647)


<p align="center">
  Orchestrate multi-agent coding on git worktrees with explicit lifecycle and state.
</p>

<p align="center">
  <img alt="codex skill" src="https://img.shields.io/badge/Codex%20Skill-Available-0f766e?style=for-the-badge">
  <img alt="version" src="https://img.shields.io/github/v/release/jaycho46/codex-teams?style=for-the-badge">
  <img alt="tests" src="https://img.shields.io/github/actions/workflow/status/jaycho46/codex-teams/ci.yml?branch=main&style=for-the-badge&label=tests">
</p>

`codex-teams` is a unified orchestration CLI for teams running parallel coding agents.
It provides an orchestration layer between worker launch and task completion:

- scheduler-ready task selection from `TODO.md`
- lock + PID based runtime safety
- explicit finish flow (`task complete`) for merge + cleanup
- interactive dashboard with emergency controls

## Start here: Codex skill (recommended)

This repo ships an installable Codex skill.

- skill manifest: `skills/.curated/codex-teams/SKILL.md`
- installer path: `skills/.curated/codex-teams`

Install with Codex skill installer:

In Codex, invoke `$skill-installer` with:

```text
$skill-installer Install skill from GitHub:
- repo: jaycho46/codex-teams
- path: skills/.curated/codex-teams
```

After install, restart Codex to pick up the skill.

If `codex-teams` is not on PATH yet, bootstrap it with the canonical installer:

```bash
REPO="${CODEX_TEAMS_REPO:-jaycho46/codex-teams}"; curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/install-codex-teams.sh" | bash -s -- --repo "$REPO" --version "${CODEX_TEAMS_VERSION:-latest}" --force
```

Use it as the default workflow:

1. In Codex task prompts, include `$codex-teams` to apply guardrails.
2. For scheduled runs, start tasks with `codex-teams run start`.
3. Monitor and control execution with `codex-teams` (TUI).

## Why codex-teams

`codex-teams` is opinionated about the full task lifecycle:

1. Start work from the scheduler (`run start`)
2. Track ownership and heartbeat with explicit runtime state
3. Finish with merge strategy + cleanup guardrails (`task complete`)

This is designed to reduce common multi-agent failure modes: duplicate starts, owner collisions, stale locks, and "done but not merged."

## 60-second quickstart

```bash
# 1) Initialize task domain and state hygiene
codex-teams init

# 2) Create a TODO task + spec template in one command
codex-teams task new T1-001 "Implement app shell bootstrap"

# 3) Fill Goal/In Scope/Acceptance Criteria in tasks/specs/T1-001.md

# 4) Start ready tasks from TODO.md
codex-teams run start

# 5) Open live dashboard (default command = status --tui)
codex-teams
```

Interactive TUI requires:

```bash
python3 -m pip install textual
```

## Install with curl

Latest release (quick install):

```bash
curl -fsSL https://raw.githubusercontent.com/jaycho46/codex-teams/main/scripts/install-codex-teams.sh | bash
```

Specific version (recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/jaycho46/codex-teams/v0.1.0/scripts/install-codex-teams.sh | bash -s -- --repo jaycho46/codex-teams --version v0.1.0
```

Specific version + signed manifest verification:

```bash
curl -fsSL https://raw.githubusercontent.com/jaycho46/codex-teams/v0.1.0/scripts/install-codex-teams.sh | bash -s -- --repo jaycho46/codex-teams --version v0.1.0 --verify-signature
```

Default install paths:

- payload: `~/.local/share/codex-teams/<version>/scripts`
- launcher: `~/.local/bin/codex-teams`

Installer verification behavior:

- checksum verification is enabled by default (`SHA256SUMS`)
- `--verify-signature` verifies `SHA256SUMS` with Sigstore cosign
- signature verification requires `cosign` installed

Manual signature verification example:

```bash
curl -fsSLO https://github.com/jaycho46/codex-teams/releases/download/v0.1.0/SHA256SUMS
curl -fsSLO https://github.com/jaycho46/codex-teams/releases/download/v0.1.0/SHA256SUMS.sig
curl -fsSLO https://github.com/jaycho46/codex-teams/releases/download/v0.1.0/SHA256SUMS.pem
cosign verify-blob \
  --certificate SHA256SUMS.pem \
  --signature SHA256SUMS.sig \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/jaycho46/codex-teams/\.github/workflows/release\.yml@.*$' \
  SHA256SUMS
```

## Entry point

```bash
codex-teams [--repo <path>] [--state-dir <path>] [--config <path>] <command>
```

No command defaults to the interactive dashboard (`status --tui`).

## System flow

```mermaid
flowchart LR
  A["TODO.md"] --> B["run start"]
  B --> C["worktree start/create"]
  C --> D["codex exec worker"]
  D --> E["task update / heartbeat"]
  E --> F["task complete"]
  F --> G["merge + cleanup + optional auto run start"]
```

## Command surface

### Status and dashboard

```bash
codex-teams
codex-teams dashboard [--trigger <label>] [--max-start <n>]
codex-teams status [--json|--tui] [--trigger <label>] [--max-start <n>]
```

What you get:

- scheduler readiness and excluded tasks (with reasons)
- runtime state counts and lock snapshots
- TUI controls: run start (`r`), emergency stop (`e`), tab switch (`1` / `2`)
- Task tab row action: select a task and press `Enter` to open its spec file
- auto-refresh every 2 seconds
- automatic fallback to text mode for non-interactive runs (CI/tests)

### Task domain

```bash
codex-teams init [--gitignore <ask|yes|no>]
codex-teams task init [--gitignore <ask|yes|no>]
codex-teams task lock <agent> <scope> [task_id]
codex-teams task unlock <agent> <scope>
codex-teams task heartbeat <agent> <scope>
codex-teams task update <agent> <task_id> <status> <summary>
codex-teams task new <task_id> <summary>
codex-teams task complete <agent> <scope> <task_id> [--summary <text>] [--trigger <label>] [--no-run-start] [--merge-strategy <ff-only|rebase-then-ff>]
codex-teams task scaffold-specs [--task <id>] [--dry-run] [--force]
codex-teams task stop (--task <id> | --owner <owner> | --all) [--reason <text>] [--apply]
codex-teams task cleanup-stale [--apply]
codex-teams task emergency-stop [--reason <text>] [--yes]
codex-teams emergency-stop [--reason <text>] [--yes]
```

Behavior notes:

- `init` (alias: `task init`) manages `.gitignore` for state path (`ask` default, `yes`, `no`)
- `task complete` does not create commits
- `task complete` requires fully committed worktree and `DONE` task status
- `task new` appends a TODO row and creates `tasks/specs/<task_id>.md` in one step
- `task scaffold-specs` creates `tasks/specs/<task_id>.md` templates from TODO items
- default merge strategy is `rebase-then-ff`; strict mode is `--merge-strategy ff-only`
- `task emergency-stop` wraps `task stop --all --apply` with confirmation

Task authoring workflow:

1. Create tasks with `codex-teams task new <task_id> <summary>`.
2. Fill `Goal`, `In Scope`, and `Acceptance Criteria` in generated spec files.
3. Verify scheduler eligibility with `codex-teams run start --dry-run`.

Detailed guide: [`docs/task-authoring-with-scaffold-specs.md`](docs/task-authoring-with-scaffold-specs.md)

Commit message contract (task worktree):

- format: `<type>: <summary> (<task_id>)`
- allowed types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`
- final DONE marker commit: `chore: mark <task_id> done`
- avoid generic messages like `update`, `done`, `task complete`

### Worktree domain

```bash
codex-teams worktree create <agent> <task_id> [base_branch] [parent_dir]
codex-teams worktree start <agent> <scope> <task_id> [base_branch] [parent_dir] [summary]
codex-teams worktree list
```

### Scheduler domain

```bash
codex-teams run start [--dry-run] [--no-launch] [--trigger <label>] [--max-start <n>]
```

Runtime behavior:

- default launches detached `codex exec` workers
- writes PID metadata to `.state/orchestrator/*.pid`
- `--no-launch` keeps start-only mode (state/worktree transitions without worker launch)
- on start/launch failure, scheduler rollback releases owned state/locks and kills spawned background workers
- launch command adds state dir and primary repo via `--add-dir` so workers can run `task update/complete`
- if `runtime.codex_flags` does not set sandbox mode, workers replace `--full-auto` with `--dangerously-bypass-approvals-and-sandbox`
- worker prompt requests `$codex-teams` skill guardrails

## Task Specs

Task specs are stored at `tasks/specs/<task_id>.md`.

Required sections:

- `## Goal`
- `## In Scope`
- `## Acceptance Criteria`

Spec helpers:

```bash
# Add one new task row and spec in one command
codex-teams task new T1-001 "Implement app shell bootstrap"

# Preview files that would be created from TODO tasks
codex-teams task scaffold-specs --dry-run

# Generate missing task specs for TODO items
codex-teams task scaffold-specs

# Generate or overwrite a specific task spec
codex-teams task scaffold-specs --task T1-001 --force
```

## Ready task selection

`run start` and `status` derive ready tasks from `TODO.md`, then exclude tasks with active signals:

- `active_worker`
- `active_lock`
- `owner_busy`
- `deps_not_ready`
- `active_signal_conflict`
- `missing_task_spec`
- `invalid_task_spec`

This blocks duplicate auto-start even when `main` branch still shows `TODO` rows while work is running in task worktrees.

## Skill files

- `skills/.curated/codex-teams/SKILL.md`: worker execution guardrails

## Bootstrap behavior

- Missing config file is auto-created at `.state/orchestrator.toml`
- Missing `TODO.md` is auto-created with a minimal table template

## Removed legacy surface

Legacy commands intentionally removed:

- `scripts/orch`
- `coord ...`
- `ops ...`
- `run status`

Use `codex-teams status` and `codex-teams task ...` instead.

## Tests

```bash
bash scripts/run_ci_tests.sh
```

CI expands that command into:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/smoke/test_run_start_dry_run.sh
bash tests/smoke/test_run_start_lock_cleanup.sh
bash tests/smoke/test_run_start_requires_task_spec.sh
bash tests/smoke/test_run_start_after_done.sh
bash tests/smoke/test_run_start_launch_codex_exec.sh
bash tests/smoke/test_run_start_rollback_kills_codex_on_launch_error.sh
bash tests/smoke/test_run_start_scenario.sh
bash tests/smoke/test_task_init_gitignore.sh
bash tests/smoke/test_task_complete_auto_run_start.sh
bash tests/smoke/test_task_complete_clears_pid_metadata.sh
bash tests/smoke/test_task_complete_commit_summary_fallback.sh
bash tests/smoke/test_task_complete_auto_rebase_merge.sh
bash tests/smoke/test_status_tui_fallback.sh
```

## GitHub release automation

This repository includes GitHub-native release automation:

- `.github/workflows/ci.yml`: runs unit + smoke checks on `main` and PRs
- `.github/workflows/release-drafter.yml`: maintains draft release notes
- `.github/workflows/release.yml`: tag-driven release publishing with signed-tag verification and Sigstore signing

Recommended branch protection on `main`:

- require pull request reviews
- require status checks (`Unit + Smoke`)
- require CODEOWNERS review for runtime/release paths

Required repository secret:

- `RELEASE_GPG_PUBLIC_KEY`: armored public key used to verify signed release tags in CI

Release flow:

```bash
git checkout main
git pull --ff-only origin main
bash scripts/run_ci_tests.sh
git tag -s v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

After tag push, `release` will:

1. rerun full tests on tag commit
2. verify GPG-signed tag using `RELEASE_GPG_PUBLIC_KEY`
3. create/update GitHub Release with generated notes
4. attach `install-codex-teams.sh`, `SHA256SUMS`, `SHA256SUMS.sig`, `SHA256SUMS.pem` assets
5. publish install and verification commands in release body

## License

MIT. See `LICENSE`.
