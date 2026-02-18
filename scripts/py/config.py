from __future__ import annotations

import json
import os
try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover
    try:
        import tomli as tomllib  # type: ignore
    except ModuleNotFoundError as exc:  # pragma: no cover
        raise RuntimeError(
            "TOML parser unavailable. Use Python 3.11+ or install tomli for Python 3.10."
        ) from exc
from copy import deepcopy
from pathlib import Path
from typing import Any


DEFAULT_CONFIG: dict[str, Any] = {
    "repo": {
        "base_branch": "main",
        "todo_file": "TODO.md",
        "state_dir": ".state",
        "worktree_parent": "../<repo>-worktrees",
    },
    "owners": {
        "AgentA": "app-shell",
        "AgentB": "domain-core",
        "AgentC": "provider-openai",
        "AgentD": "ui-popover",
        "AgentE": "ci-release",
    },
    "runtime": {
        "max_start": 0,
        "launch_backend": "tmux",
        "auto_no_launch": False,
        "codex_flags": "--full-auto -m gpt-5.3-codex -c model_reasoning_effort=\"medium\"",
    },
    "todo": {
        "id_col": 2,
        "title_col": 3,
        "owner_col": 4,
        "deps_col": 5,
        "status_col": 7,
        "gate_regex": r"`(G[0-9]+ \\([^)]+\\))`",
        "done_keywords": ["DONE", "완료", "Complete", "complete"],
    },
}


class ConfigError(RuntimeError):
    pass


def _bootstrap_config_if_missing(cfg_path: Path) -> None:
    if cfg_path.exists():
        return

    cfg_path.parent.mkdir(parents=True, exist_ok=True)

    inferred_repo_name = cfg_path.parent.parent.name if cfg_path.parent.name == ".state" else cfg_path.parent.name
    default_worktree_parent = str(DEFAULT_CONFIG["repo"]["worktree_parent"]).replace("<repo>", inferred_repo_name)

    def q(value: str) -> str:
        # JSON string escaping is TOML-basic-string compatible.
        return json.dumps(value, ensure_ascii=False)

    template = f"""[repo]
base_branch = {q(str(DEFAULT_CONFIG["repo"]["base_branch"]))}
todo_file = {q(str(DEFAULT_CONFIG["repo"]["todo_file"]))}
state_dir = {q(str(DEFAULT_CONFIG["repo"]["state_dir"]))}
worktree_parent = {q(default_worktree_parent)}

[owners]
AgentA = {q(str(DEFAULT_CONFIG["owners"]["AgentA"]))}
AgentB = {q(str(DEFAULT_CONFIG["owners"]["AgentB"]))}
AgentC = {q(str(DEFAULT_CONFIG["owners"]["AgentC"]))}
AgentD = {q(str(DEFAULT_CONFIG["owners"]["AgentD"]))}
AgentE = {q(str(DEFAULT_CONFIG["owners"]["AgentE"]))}

[runtime]
max_start = {int(DEFAULT_CONFIG["runtime"]["max_start"])}
launch_backend = {q(str(DEFAULT_CONFIG["runtime"]["launch_backend"]))}
auto_no_launch = {str(bool(DEFAULT_CONFIG["runtime"]["auto_no_launch"])).lower()}
codex_flags = {q(str(DEFAULT_CONFIG["runtime"]["codex_flags"]))}

[todo]
id_col = {int(DEFAULT_CONFIG["todo"]["id_col"])}
title_col = {int(DEFAULT_CONFIG["todo"]["title_col"])}
owner_col = {int(DEFAULT_CONFIG["todo"]["owner_col"])}
deps_col = {int(DEFAULT_CONFIG["todo"]["deps_col"])}
status_col = {int(DEFAULT_CONFIG["todo"]["status_col"])}
gate_regex = {q(str(DEFAULT_CONFIG["todo"]["gate_regex"]))}
done_keywords = ["DONE", "완료", "Complete", "complete"]
"""
    cfg_path.write_text(template, encoding="utf-8")


def owner_key(owner: str) -> str:
    return "".join(ch.lower() for ch in owner if ch.isalnum())


def _deep_merge(base: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    merged = deepcopy(base)
    for key, value in incoming.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def _to_abs(base: Path, value: str) -> Path:
    p = Path(value).expanduser()
    if p.is_absolute():
        return p
    return (base / p).resolve()


def _expand_repo_placeholder(value: str, repo_name: str) -> str:
    return value.replace("<repo>", repo_name)


def _repo_root_from_config_path(cfg_path: Path, fallback_repo_root: Path) -> Path:
    # If config is placed at <repo>/.state/orchestrator.toml, resolve relative
    # repo paths (TODO.md, worktree_parent, state_dir) from that repo root.
    if cfg_path.parent.name == ".state":
        return cfg_path.parent.parent.resolve()
    return fallback_repo_root


def load_config(repo_root: Path, config_path: str | None = None) -> tuple[dict[str, Any], Path]:
    cfg_path = Path(config_path).expanduser() if config_path else (repo_root / ".state" / "orchestrator.toml")
    if not cfg_path.is_absolute():
        cfg_path = (repo_root / cfg_path).resolve()

    _bootstrap_config_if_missing(cfg_path)

    try:
        parsed = tomllib.loads(cfg_path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML in {cfg_path}: {exc}") from exc

    if not isinstance(parsed, dict):
        raise ConfigError(f"invalid config root (expected table): {cfg_path}")

    merged = _deep_merge(DEFAULT_CONFIG, parsed)

    owners = merged.get("owners", {})
    if not isinstance(owners, dict) or not owners:
        raise ConfigError("[owners] must be a non-empty table")

    todo = merged.get("todo", {})
    for key in ("id_col", "title_col", "owner_col", "deps_col", "status_col"):
        value = todo.get(key)
        if not isinstance(value, int) or value < 1:
            raise ConfigError(f"todo.{key} must be an integer >= 1")

    if not isinstance(todo.get("done_keywords"), list) or not todo["done_keywords"]:
        raise ConfigError("todo.done_keywords must be a non-empty list")

    launch_backend = str(merged.get("runtime", {}).get("launch_backend", "")).strip().lower()
    if launch_backend not in {"auto", "tmux", "codex_exec"}:
        raise ConfigError(
            "runtime.launch_backend must be one of: auto, tmux, codex_exec"
        )
    merged["runtime"]["launch_backend"] = launch_backend

    config_repo_root = _repo_root_from_config_path(cfg_path, repo_root)
    merged["repo"]["worktree_parent"] = _expand_repo_placeholder(
        str(merged["repo"]["worktree_parent"]), config_repo_root.name
    )

    return merged, cfg_path


def resolve_context(
    repo_root: Path,
    config: dict[str, Any],
    state_dir_arg: str | None = None,
    config_path: Path | None = None,
) -> dict[str, Any]:
    repo_name = repo_root.name
    repo_parent = repo_root.parent

    config_repo_root = _repo_root_from_config_path(config_path, repo_root) if config_path else repo_root

    todo_file = _to_abs(config_repo_root, str(config["repo"]["todo_file"]))
    worktree_parent = _to_abs(config_repo_root, str(config["repo"]["worktree_parent"]))

    state_src = state_dir_arg or os.getenv("AI_STATE_DIR") or str(config["repo"]["state_dir"])
    state_base = repo_root if (state_dir_arg or os.getenv("AI_STATE_DIR")) else config_repo_root
    state_dir = _to_abs(state_base, state_src)

    lock_dir = state_dir / "locks"
    orch_dir = state_dir / "orchestrator"
    updates_file = state_dir / "LATEST_UPDATES.md"

    runtime = {
        "max_start": int(config["runtime"]["max_start"]),
        "launch_backend": str(config["runtime"]["launch_backend"]),
        "auto_no_launch": bool(config["runtime"]["auto_no_launch"]),
        "codex_flags": str(config["runtime"]["codex_flags"]),
    }

    owners_raw = {str(k): str(v) for k, v in config["owners"].items()}
    owners_by_key = {owner_key(k): v for k, v in owners_raw.items()}

    return {
        "repo_root": str(repo_root),
        "repo_name": repo_name,
        "repo_parent": str(repo_parent),
        "base_branch": str(config["repo"]["base_branch"]),
        "todo_file": str(todo_file),
        "state_dir": str(state_dir),
        "lock_dir": str(lock_dir),
        "orch_dir": str(orch_dir),
        "updates_file": str(updates_file),
        "worktree_parent": str(worktree_parent),
        "runtime": runtime,
        "todo": config["todo"],
        "owners": owners_raw,
        "owners_by_key": owners_by_key,
    }
