from __future__ import annotations

import json
import os
import re
from copy import deepcopy
from pathlib import Path
from typing import Any

try:
    import tomllib as _toml  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover
    try:
        import tomli as _toml  # type: ignore
    except ModuleNotFoundError:  # pragma: no cover
        _toml = None

_INT_RE = re.compile(r"^[+-]?\d+$")


class _TomlDecodeError(ValueError):
    pass


def _strip_toml_comment(line: str) -> str:
    in_single = False
    in_double = False
    escaped = False

    for idx, ch in enumerate(line):
        if in_double:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
            continue

        if in_single:
            if ch == "'":
                in_single = False
            continue

        if ch == "#":
            return line[:idx]
        if ch == '"':
            in_double = True
        elif ch == "'":
            in_single = True

    return line


def _split_toml_list_items(raw: str) -> list[str]:
    items: list[str] = []
    token: list[str] = []
    in_single = False
    in_double = False
    escaped = False
    depth = 0

    for ch in raw:
        if in_double:
            token.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
            continue

        if in_single:
            token.append(ch)
            if ch == "'":
                in_single = False
            continue

        if ch == '"':
            in_double = True
            token.append(ch)
            continue

        if ch == "'":
            in_single = True
            token.append(ch)
            continue

        if ch == "[":
            depth += 1
            token.append(ch)
            continue

        if ch == "]":
            depth = max(0, depth - 1)
            token.append(ch)
            continue

        if ch == "," and depth == 0:
            items.append("".join(token).strip())
            token = []
            continue

        token.append(ch)

    tail = "".join(token).strip()
    if tail:
        items.append(tail)
    return items


def _parse_toml_value(raw: str) -> Any:
    value = raw.strip()
    if not value:
        raise _TomlDecodeError("empty TOML value")

    if value.startswith('"') and value.endswith('"'):
        try:
            return json.loads(value)
        except json.JSONDecodeError as exc:
            raise _TomlDecodeError(str(exc)) from exc

    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]

    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False

    if _INT_RE.match(value):
        return int(value)

    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [_parse_toml_value(part) for part in _split_toml_list_items(inner)]

    raise _TomlDecodeError(f"unsupported TOML value: {value}")


def _loads_toml_fallback(text: str) -> dict[str, Any]:
    root: dict[str, Any] = {}
    current: dict[str, Any] = root

    for lineno, raw_line in enumerate(text.splitlines(), start=1):
        line = _strip_toml_comment(raw_line).strip()
        if not line:
            continue

        if line.startswith("[") and line.endswith("]"):
            section_name = line[1:-1].strip()
            if not section_name:
                raise _TomlDecodeError(f"line {lineno}: empty section header")

            current = root
            for part in section_name.split("."):
                key = part.strip()
                if not key:
                    raise _TomlDecodeError(f"line {lineno}: invalid section header")
                node = current.get(key)
                if node is None:
                    node = {}
                    current[key] = node
                if not isinstance(node, dict):
                    raise _TomlDecodeError(
                        f"line {lineno}: section collides with non-table key '{key}'"
                    )
                current = node
            continue

        if "=" not in line:
            raise _TomlDecodeError(f"line {lineno}: expected key=value")

        key_part, value_part = line.split("=", 1)
        key = key_part.strip()
        if not key:
            raise _TomlDecodeError(f"line {lineno}: missing key before '='")

        current[key] = _parse_toml_value(value_part)

    return root


if _toml is not None:  # pragma: no cover - depends on runtime
    _TOML_DECODE_ERROR = getattr(_toml, "TOMLDecodeError", ValueError)

    def _loads_toml(text: str) -> dict[str, Any]:
        return _toml.loads(text)

else:
    _TOML_DECODE_ERROR = _TomlDecodeError

    def _loads_toml(text: str) -> dict[str, Any]:
        return _loads_toml_fallback(text)


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
        parsed = _loads_toml(cfg_path.read_text(encoding="utf-8"))
    except _TOML_DECODE_ERROR as exc:
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
