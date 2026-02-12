# Task Authoring with `scaffold-specs`

This workflow turns TODO rows into executable task specs so workers do not run from one-line titles only.

## Quick Checklist

1. Initialize repository state.
2. Create tasks with `task new`.
3. Fill required sections in each spec.
4. Confirm readiness with a dry-run scheduler check.
5. Start scheduler.

```bash
# 1) initialize
codex-teams init

# 2) create task row + spec template together
codex-teams task new T2-101 "Billing webhook retry policy"

# optional: set prerequisite task ids
codex-teams task new T2-102 --deps T2-101 "Billing webhook retry jitter tuning"

# 3) edit generated files in tasks/specs/*.md

# 4) verify scheduler eligibility
codex-teams run start --dry-run

# 5) run workers
codex-teams run start
```

## TODO Row Format

Use the standard table shape:

```md
| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T2-101 | Billing webhook retry policy | AgentB | T2-100 | needs backfill | TODO |
```

## Create Tasks Quickly

Recommended path:

```bash
codex-teams task new T2-101 "Billing webhook retry policy"
```

What this does:

- appends a `TODO` row to `TODO.md`
- uses the default owner (first entry in `[owners]` config)
- records prerequisites in `Deps` when `--deps` is provided (comma/space separated task ids)
- creates `tasks/specs/T2-101.md`

## Generate Specs (Bulk / Existing TODO Rows)

Generate for every `TODO` row:

```bash
codex-teams task scaffold-specs
```

Preview without writing:

```bash
codex-teams task scaffold-specs --dry-run
```

Generate a specific task only:

```bash
codex-teams task scaffold-specs --task T2-101
```

Overwrite an existing spec:

```bash
codex-teams task scaffold-specs --task T2-101 --force
```

## Required Spec Sections

Each `tasks/specs/<TASK_ID>.md` file must include these exact section headings:

- `## Goal`
- `## In Scope`
- `## Acceptance Criteria`

Template:

```md
# Task Spec: T2-101

Task title: Billing webhook retry policy

## Goal
Define the concrete outcome for T2-101.

## In Scope
- Describe what must be implemented for this task.
- List files, modules, or behaviors that are in scope.

## Acceptance Criteria
- [ ] Implementation is complete and testable.
- [ ] Relevant tests or validation steps are added or updated.
- [ ] Changes are ready to merge with a clear completion summary.
```

## Strong Migration Warning

Scheduler readiness now enforces task specs.

- If spec file is missing, task is excluded with `reason=missing_task_spec`.
- If required sections are missing/empty, task is excluded with `reason=invalid_task_spec`.

Immediate recovery sequence:

1. Run `codex-teams task new <task_id> [--deps <task_id[,task_id...]>] <summary>` for new tasks, or `task scaffold-specs` for existing rows.
2. Fill required sections in generated spec files.
3. Re-run `codex-teams run start --dry-run`.
4. Confirm exclusion reason is gone, then run `codex-teams run start`.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `reason=missing_task_spec` | `tasks/specs/<task_id>.md` does not exist | Run `codex-teams task scaffold-specs` and commit the new file |
| `reason=invalid_task_spec` | Missing or empty `Goal`, `In Scope`, or `Acceptance Criteria` | Fill all required sections with non-empty content |
| Task still excluded after spec update | TODO status/deps/owner rules still block it | Check `owner_busy`, `deps_not_ready`, and active lock/worker reasons |
