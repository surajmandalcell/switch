#!/usr/bin/env python3
"""Verify Codex local history through the installed app-server RPCs.

The verifier is deliberately local and read-only with respect to the supplied
history root. It creates two private neutral homes, links only sessions and
archived_sessions, and talks to each app-server through initialize,
thread/list, thread/read, and thread/resume. It never starts a turn or sends a
model request.

For a real imported snapshot, pass --state-db and, when paginated history is
present, --history-db. Also pass the imported --account-home so stored rollout
paths can be checked without remapping stale prefixes. A small synthetic fixture
may omit all three database arguments and is discovered through Codex scanning.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import selectors
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from typing import Any, Iterable


PRIVATE_TMP = Path("/private/tmp").resolve()
RPC_METHODS = {"initialize", "thread/list", "thread/read", "thread/resume"}
CREDENTIAL_ENVIRONMENT_KEYS = {
    "OPENAI_API_KEY",
    "OPENAI_ACCESS_TOKEN",
    "CODEX_ACCESS_TOKEN",
    "CODEX_API_KEY",
    "CODEX_AUTH_TOKEN",
    "CHATGPT_TOKEN",
}


class VerificationError(RuntimeError):
    pass


@dataclass
class ThreadRecord:
    thread_id: str
    rollout_path: Path | None
    history_mode: str
    row: dict[str, Any]


def is_contained(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def canonical_private_lexical(path: Path) -> Path:
    parts = path.parts
    if len(parts) >= 2 and parts[:2] == ("/", "tmp"):
        return PRIVATE_TMP.joinpath(*parts[2:])
    return path


def private_path(value: str, label: str, must_exist: bool = True) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise VerificationError(f"{label} must be absolute")
    try:
        resolved = path.resolve(strict=must_exist)
    except OSError as error:
        raise VerificationError(f"{label} is unavailable") from error
    if not is_contained(resolved, PRIVATE_TMP):
        raise VerificationError(f"{label} must be under /private/tmp")
    if must_exist and not resolved.is_file() and label.endswith("database"):
        raise VerificationError(f"{label} is not a regular file")
    return resolved


def reject_links(root: Path) -> None:
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in [*directories, *files]:
            if Path(directory, name).is_symlink():
                raise VerificationError("selected history directories contain a symbolic link")


def selected_history_directories(root: Path) -> list[tuple[str, Path]]:
    sessions = root / "sessions"
    archived = root / "archived_sessions"
    if not sessions.is_dir() or sessions.is_symlink():
        raise VerificationError("transcript root must contain a regular sessions directory")
    directories = [("sessions", sessions)]
    if archived.exists():
        if not archived.is_dir() or archived.is_symlink():
            raise VerificationError("archived_sessions must be a regular directory")
        directories.append(("archived_sessions", archived))
    for _, directory in directories:
        reject_links(directory)
    return directories


def make_uuid7() -> str:
    timestamp = int(time.time() * 1000) & ((1 << 48) - 1)
    value = timestamp << 80
    value |= 0x7 << 76
    value |= secrets.randbits(76)
    value &= ~(0x3 << 62)
    value |= 0x2 << 62
    return str(uuid.UUID(int=value))


def synthetic_row(thread_id: str, rollout_path: Path, archived: bool = False) -> ThreadRecord:
    now = int(time.time())
    return ThreadRecord(
        thread_id=thread_id,
        rollout_path=rollout_path,
        history_mode="legacy",
        row={
            "id": thread_id,
            "rollout_path": str(rollout_path),
            "created_at": now,
            "updated_at": now,
            "source": "cli",
            "model_provider": "openai",
            "cwd": "/private/tmp/ai-manager-history-project",
            "title": "",
            "sandbox_policy": "{}",
            "approval_mode": "never",
            "tokens_used": 0,
            "has_user_event": 1,
            "archived": 1 if archived else 0,
            "preview": "local history",
            "cli_version": "0.154.0",
            "first_user_message": "",
            "thread_source": "cli",
            "history_mode": "legacy",
            "recency_at": now,
            "recency_at_ms": now * 1000,
        },
    )


def scan_fixture_records(root: Path, maximum: int) -> list[ThreadRecord]:
    records: list[ThreadRecord] = []
    seen: set[str] = set()
    for directory_name, directory in selected_history_directories(root):
        for current, _, files in os.walk(directory, followlinks=False):
            for filename in sorted(files):
                if not filename.endswith(".jsonl"):
                    continue
                path = Path(current, filename)
                try:
                    with path.open("rb") as handle:
                        found: str | None = None
                        for _ in range(32):
                            line = handle.readline(65_536)
                            if not line:
                                break
                            try:
                                event = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            if event.get("type") != "session_meta":
                                continue
                            payload = event.get("payload")
                            if isinstance(payload, dict) and isinstance(payload.get("id"), str):
                                found = payload["id"]
                                break
                except OSError as error:
                    raise VerificationError("could not inspect a selected transcript") from error
                if not found or found in seen:
                    continue
                seen.add(found)
                records.append(synthetic_row(found, path, directory_name == "archived_sessions"))
                if len(records) > maximum:
                    raise VerificationError("fixture transcript count exceeds the configured bound")
    if not records:
        raise VerificationError("no session_meta records were found in the selected history")
    return records


def rollout_path_status(raw: Any, root: Path, account_home: Path) -> tuple[str, Path | None]:
    if not isinstance(raw, str) or not raw:
        return "unmapped", None
    candidate = canonical_private_lexical(Path(raw))
    account_home = canonical_private_lexical(account_home)
    if not candidate.is_absolute():
        return "unmapped", None
    try:
        relative = candidate.relative_to(account_home)
    except ValueError:
        return "escaping", None
    if not relative.parts or relative.parts[0] not in ("sessions", "archived_sessions"):
        return "unmapped", None
    mapped = root.joinpath(relative)
    try:
        resolved = mapped.resolve(strict=False)
    except OSError:
        return "unmapped", None
    if not is_contained(resolved, root):
        return "escaping", None
    if mapped.is_file() and not mapped.is_symlink():
        return "present", mapped
    return "missing", None


def read_state_records(
    database: Path,
    root: Path,
    account_home: Path,
    expected_ids: set[str],
    maximum: int,
) -> list[ThreadRecord]:
    uri = f"file:{database.as_posix()}?mode=ro"
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(uri, uri=True)
        connection.row_factory = sqlite3.Row
        rows = connection.execute("SELECT * FROM threads LIMIT ?", (maximum + 1,)).fetchall()
    except sqlite3.Error as error:
        raise VerificationError("could not read the supplied state database") from error
    finally:
        if connection is not None:
            connection.close()

    records: list[ThreadRecord] = []
    for sqlite_row in rows:
        row = dict(sqlite_row)
        thread_id = row.get("id")
        if not isinstance(thread_id, str) or (expected_ids and thread_id not in expected_ids):
            continue
        history_mode = row.get("history_mode") or "legacy"
        status, rollout_path = rollout_path_status(row.get("rollout_path"), root, account_home)
        if status != "present":
            continue
        records.append(ThreadRecord(thread_id, rollout_path, str(history_mode), row))
        if len(records) > maximum:
            raise VerificationError("state database thread count exceeds the configured bound")

    found_ids = {record.thread_id for record in records}
    if expected_ids and found_ids != expected_ids:
        raise VerificationError("the supplied state database does not cover every expected thread")
    if not records:
        raise VerificationError("the supplied state database has no selected local threads")
    return records


def projection_presence(database: Path, thread_ids: list[str]) -> tuple[set[str], set[str]]:
    item_ids: set[str] = set()
    turn_ids: set[str] = set()
    connection = sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True)
    try:
        for start in range(0, len(thread_ids), 400):
            batch = thread_ids[start : start + 400]
            placeholders = ",".join("?" for _ in batch)
            for table, target in (("thread_items", item_ids), ("thread_turns", turn_ids)):
                query = f"SELECT thread_id FROM {table} WHERE thread_id IN ({placeholders}) GROUP BY thread_id"
                target.update(str(row[0]) for row in connection.execute(query, batch))
    except sqlite3.Error as error:
        raise VerificationError("could not read the supplied history projection") from error
    finally:
        connection.close()
    return item_ids, turn_ids


def preflight_state(
    database: Path,
    root: Path,
    account_home: Path,
    history_database: Path | None,
    maximum: int,
) -> dict[str, Any]:
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True)
        rows = connection.execute(
            "SELECT id, rollout_path, history_mode FROM threads LIMIT ?", (maximum + 1,)
        ).fetchall()
    except sqlite3.Error as error:
        raise VerificationError("could not read the supplied state database") from error
    finally:
        if connection is not None:
            connection.close()
    if len(rows) > maximum:
        raise VerificationError("state database thread count exceeds the configured bound")

    missing_by_mode: dict[str, list[str]] = {"legacy": [], "paginated": [], "other": []}
    escaping_by_mode: dict[str, list[str]] = {"legacy": [], "paginated": [], "other": []}
    unmapped_by_mode: dict[str, list[str]] = {"legacy": [], "paginated": [], "other": []}
    mapped_rows = 0
    for thread_id, raw_rollout_path, raw_history_mode in rows:
        history_mode = str(raw_history_mode or "legacy").lower()
        mode = history_mode if history_mode in missing_by_mode else "other"
        status, _ = rollout_path_status(raw_rollout_path, root, account_home)
        if status == "missing":
            missing_by_mode[mode].append(str(thread_id))
        elif status == "escaping":
            escaping_by_mode[mode].append(str(thread_id))
        elif status == "unmapped":
            unmapped_by_mode[mode].append(str(thread_id))
        elif status == "present":
            mapped_rows += 1

    missing_ids = [thread_id for values in missing_by_mode.values() for thread_id in values]
    item_ids: set[str] = set()
    turn_ids: set[str] = set()
    if history_database is not None and missing_ids:
        item_ids, turn_ids = projection_presence(history_database, missing_ids)
    missing_legacy = set(missing_by_mode["legacy"])
    missing_paginated = set(missing_by_mode["paginated"])
    missing_other = set(missing_by_mode["other"])
    paginated_with_items = missing_paginated & item_ids
    paginated_with_turns = missing_paginated & turn_ids
    paginated_with_projection = paginated_with_items & paginated_with_turns
    paginated_partial_projection = (paginated_with_items ^ paginated_with_turns) & missing_paginated
    paginated_without_projection = missing_paginated - (item_ids | turn_ids)
    legacy_with_projection = missing_legacy & (item_ids | turn_ids)
    escaping_rows = sum(len(values) for values in escaping_by_mode.values())
    unmapped_rows = sum(len(values) for values in unmapped_by_mode.values())
    invalid_paginated = missing_paginated | set(escaping_by_mode["paginated"]) | set(unmapped_by_mode["paginated"])
    invalid_legacy = (
        missing_legacy
        | set(escaping_by_mode["legacy"])
        | set(unmapped_by_mode["legacy"])
    )
    invalid_other = (
        set(missing_by_mode["other"])
        | set(escaping_by_mode["other"])
        | set(unmapped_by_mode["other"])
    )
    return {
        "preflight": True,
        "neutral_verifier_started": False,
        "state_rows": len(rows),
        "mapped_rollout_rows": mapped_rows,
        "missing_rollout_rows": len(missing_ids),
        "unresolved_rollout_rows": len(missing_ids) + escaping_rows + unmapped_rows,
        "legacy_missing_rollout_rows": len(missing_legacy),
        "paginated_missing_rollout_rows": len(missing_paginated),
        "other_missing_rollout_rows": len(missing_other),
        "escaping_live_reference_rows": escaping_rows,
        "unmapped_rollout_rows": unmapped_rows,
        "legacy_missing_with_projection_rows": len(legacy_with_projection),
        "legacy_missing_without_projection_rows": len(missing_legacy - (item_ids | turn_ids)),
        "paginated_missing_with_projection_rows": len(paginated_with_projection),
        "paginated_missing_with_partial_projection_rows": len(paginated_partial_projection),
        "paginated_missing_without_projection_rows": len(paginated_without_projection),
        "active_database_only_unsupported_rows": len(paginated_with_projection),
        "projection_database_supplied": history_database is not None,
        "all_rollout_paths_resolve": not (missing_ids or escaping_rows or unmapped_rows),
        "preflight_ok": not (invalid_legacy or invalid_paginated or invalid_other),
    }


def write_transcript(path: Path, thread_id: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = [
        {
            "timestamp": "2099-01-01T00:00:00.000Z",
            "type": "session_meta",
            "payload": {
                "id": thread_id,
                "timestamp": "2099-01-01T00:00:00.000Z",
                "cwd": "/private/tmp/ai-manager-history-project",
                "originator": "codex_cli_rs",
                "cli_version": "0.154.0",
                "model_provider": "openai",
                "source": "cli",
            },
        },
        {
            "timestamp": "2099-01-01T00:00:00.001Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "local history check", "kind": "plain"},
        },
    ]
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")
    path.chmod(0o600)


def copy_private_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            ["cp", "-c", str(source), str(destination)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=300,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        shutil.copy2(source, destination)
    destination.chmod(0o600)
    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(source) + suffix)
        if sidecar.exists():
            copy_private_file(sidecar, Path(str(destination) + suffix))


def install_database(source: Path, destination: Path) -> None:
    for path in (destination, Path(str(destination) + "-wal"), Path(str(destination) + "-shm")):
        path.unlink(missing_ok=True)
    copy_private_file(source, destination)


class AppServer:
    def __init__(self, codex: str, environment: dict[str, str], timeout: float, max_response_bytes: int):
        self.codex = codex
        self.environment = environment
        self.timeout = timeout
        self.max_response_bytes = max_response_bytes
        self.process: subprocess.Popen[bytes] | None = None
        self.selector: selectors.BaseSelector[Any] | None = None
        self.next_id = 1
        self.read_buffer = bytearray()

    def start(self) -> None:
        self.process = subprocess.Popen(
            [self.codex, "app-server", "--stdio", "-c", 'cli_auth_credentials_store="file"', "-c", "analytics.enabled=false"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=self.environment,
            cwd="/private/tmp",
        )
        self.selector = selectors.DefaultSelector()
        assert self.process.stdout is not None
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method not in RPC_METHODS:
            raise VerificationError("verifier attempted an unsupported app-server method")
        if self.process is None or self.process.stdin is None or self.selector is None:
            raise VerificationError("app-server is not running")
        request_id = self.next_id
        self.next_id += 1
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        self.process.stdin.write(payload)
        self.process.stdin.flush()
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            events = self.selector.select(max(0.0, deadline - time.monotonic()))
            for _, _ in events:
                assert self.process.stdout is not None
                remaining = self.max_response_bytes + 1 - len(self.read_buffer)
                if remaining <= 0:
                    raise VerificationError("app-server response exceeded the configured bound")
                chunk = os.read(self.process.stdout.fileno(), min(65_536, remaining))
                if not chunk:
                    raise VerificationError("app-server closed before the RPC response")
                self.read_buffer.extend(chunk)
                if len(self.read_buffer) > self.max_response_bytes:
                    raise VerificationError("app-server response exceeded the configured bound")
                while b"\n" in self.read_buffer:
                    line, _, remainder = self.read_buffer.partition(b"\n")
                    self.read_buffer = bytearray(remainder)
                    if len(line) > self.max_response_bytes:
                        raise VerificationError("app-server response exceeded the configured bound")
                    try:
                        response = json.loads(line.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError) as error:
                        raise VerificationError("app-server returned a non-JSON response") from error
                    if response.get("id") != request_id:
                        continue
                    if "error" in response:
                        raise VerificationError(f"app-server rejected {method}")
                    result = response.get("result")
                    if not isinstance(result, dict):
                        raise VerificationError(f"app-server returned an invalid {method} result")
                    return result
        raise VerificationError(f"app-server {method} timed out")

    def initialize(self) -> None:
        result = self.request(
            "initialize",
            {
                "clientInfo": {"name": "ai-manager-history-verifier", "version": "0.1"},
                "capabilities": {"experimentalApi": False},
            },
        )
        if result.get("codexHome") != self.environment.get("CODEX_HOME"):
            raise VerificationError("app-server did not use the neutral CODEX_HOME")
        if self.process is None or self.process.stdin is None:
            raise VerificationError("app-server stdin is unavailable")
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"initialized","params":{}}\n')
        self.process.stdin.flush()

    def stop(self) -> None:
        process = self.process
        self.process = None
        if self.selector is not None:
            self.selector.close()
            self.selector = None
        if process is None:
            return
        try:
            if process.stdin is not None:
                process.stdin.close()
        except OSError:
            pass
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)

    def __enter__(self) -> "AppServer":
        self.start()
        try:
            self.initialize()
        except Exception:
            self.stop()
            raise
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.stop()


def neutral_environment(home: Path, codex_home: Path) -> dict[str, str]:
    environment = dict(os.environ)
    for key in CREDENTIAL_ENVIRONMENT_KEYS:
        environment.pop(key, None)
    environment.update(
        {
            "HOME": str(home),
            "CODEX_HOME": str(codex_home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "TMPDIR": str(codex_home / "tmp"),
            "CODEX_ANALYTICS_ENABLED": "0",
        }
    )
    return environment


def prepare_home(
    home: Path,
    codex_home: Path,
    source_root: Path,
    state_db: Path | None,
    history_db: Path | None,
    codex: str,
    timeout: float,
    max_response_bytes: int,
) -> dict[str, str]:
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    codex_home.mkdir(parents=True, exist_ok=True, mode=0o700)
    (codex_home / "tmp").mkdir(mode=0o700)
    (home / ".config").mkdir(mode=0o700)
    (home / ".cache").mkdir(mode=0o700)
    config = codex_home / "config.toml"
    config.write_text('cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n', encoding="utf-8")
    config.chmod(0o600)
    for name in ("sessions", "archived_sessions"):
        source = source_root / name
        if not source.exists():
            continue
        os.symlink(source, codex_home / name, target_is_directory=True)
    environment = neutral_environment(home, codex_home)
    with AppServer(codex, environment, timeout, max_response_bytes):
        pass
    if state_db is not None:
        install_database(state_db, codex_home / "state_5.sqlite")
    if history_db is not None:
        install_database(history_db, codex_home / "thread_history_1.sqlite")
    return environment


def list_threads(
    server: AppServer,
    page_size: int,
    maximum: int,
    state_db_only: bool,
    source_kinds: list[str] | None = None,
) -> dict[str, dict[str, Any]]:
    threads: dict[str, dict[str, Any]] = {}
    for archived in (False, True):
        cursor: str | None = None
        for _ in range(100):
            params: dict[str, Any] = {
                "archived": archived,
                "cursor": cursor,
                "limit": page_size,
                "sourceKinds": [] if source_kinds is None else source_kinds,
                "useStateDbOnly": state_db_only,
            }
            result = server.request("thread/list", params)
            data = result.get("data")
            if not isinstance(data, list):
                raise VerificationError("thread/list returned invalid data")
            for item in data:
                if isinstance(item, dict) and isinstance(item.get("id"), str):
                    threads[item["id"]] = item
            if len(threads) > maximum:
                raise VerificationError("listed thread count exceeds the configured bound")
            cursor = result.get("nextCursor")
            if not cursor:
                break
        else:
            raise VerificationError("thread/list pagination exceeded the configured bound")
    return threads


def read_threads(server: AppServer, thread_ids: Iterable[str], include_turns: bool = False) -> int:
    count = 0
    for thread_id in thread_ids:
        result = server.request("thread/read", {"threadId": thread_id, "includeTurns": include_turns})
        thread = result.get("thread")
        if not isinstance(thread, dict) or thread.get("id") != thread_id:
            raise VerificationError("thread/read returned the wrong thread")
        if include_turns and not isinstance(thread.get("turns"), list):
            raise VerificationError("paginated thread/read did not return a turns list")
        count += 1
    return count


def resume_threads(server: AppServer, thread_ids: Iterable[str]) -> int:
    count = 0
    for thread_id in thread_ids:
        result = server.request(
            "thread/resume",
            {
                "threadId": thread_id,
                "excludeTurns": False,
                "approvalPolicy": "never",
                "sandbox": "read-only",
            },
        )
        thread = result.get("thread")
        if not isinstance(thread, dict) or thread.get("id") != thread_id:
            raise VerificationError("thread/resume returned the wrong thread")
        count += 1
    return count


def verify_home(
    codex: str,
    environment: dict[str, str],
    expected: list[ThreadRecord],
    timeout: float,
    max_response_bytes: int,
    page_size: int,
    maximum: int,
    paginated_read_ids: set[str],
    read_ids: set[str],
    resume_ids: set[str],
    state_db_only: bool = True,
    require_all_expected: bool = True,
) -> tuple[set[str], int, bool, int]:
    expected_ids = {record.thread_id for record in expected}
    record_by_id = {record.thread_id: record for record in expected}
    with AppServer(codex, environment, timeout, max_response_bytes) as server:
        listed = list_threads(server, page_size, maximum, state_db_only)
        listed_ids = set(listed)
        if require_all_expected and not expected_ids.issubset(listed_ids):
            missing_ids = expected_ids - listed_ids
            missing_paginated = sum(
                1 for thread_id in missing_ids if record_by_id[thread_id].history_mode.lower() == "paginated"
            )
            raise VerificationError(
                "thread/list omitted "
                f"{len(missing_ids)} expected threads "
                f"({missing_paginated} paginated, {len(missing_ids) - missing_paginated} other)"
            )
        selected_ids = read_ids | paginated_read_ids | resume_ids
        if not selected_ids.issubset(listed_ids):
            raise VerificationError("the interactive thread list omitted a selected read or resume thread")
        read_count = read_threads(server, sorted(read_ids))
        paginated_ok = not paginated_read_ids
        for paginated_id in sorted(paginated_read_ids):
            if paginated_id not in record_by_id or record_by_id[paginated_id].history_mode.lower() != "paginated":
                raise VerificationError("requested paginated thread is not marked paginated")
            read_threads(server, [paginated_id], include_turns=True)
            paginated_ok = True
        resume_count = resume_threads(server, sorted(resume_ids))
    return listed_ids, read_count, paginated_ok, resume_count


def verify_native_later_discovery(
    run_root: Path,
    codex: str,
    timeout: float,
    max_response_bytes: int,
    page_size: int,
    maximum: int,
) -> bool:
    shared_root = run_root / "later-shared"
    (shared_root / "sessions").mkdir(parents=True, mode=0o700)
    (shared_root / "archived_sessions").mkdir(mode=0o700)
    environments: list[dict[str, str]] = []
    for name in ("later-a", "later-b"):
        environments.append(
            prepare_home(
                run_root / f"{name}-home",
                run_root / f"{name}-codex",
                shared_root,
                None,
                None,
                codex,
                timeout,
                max_response_bytes,
            )
        )

    later_id = make_uuid7()
    later_path = shared_root / "sessions/2099/01/01" / f"rollout-2099-01-01T00-00-00-{later_id}.jsonl"
    write_transcript(later_path, later_id)
    for environment in environments:
        with AppServer(codex, environment, timeout, max_response_bytes) as server:
            if later_id not in list_threads(server, page_size, maximum, state_db_only=False):
                raise VerificationError("native scanning omitted the later shared thread")
            read_threads(server, [later_id])
        with AppServer(codex, environment, timeout, max_response_bytes) as server:
            if later_id not in list_threads(server, page_size, maximum, state_db_only=True):
                raise VerificationError("native scanning did not repair the local state index")
    return True


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transcript-root", required=True, help="Imported sessions root under /private/tmp")
    parser.add_argument("--account-home", help="Owning imported Codex home under /private/tmp; required with --state-db")
    parser.add_argument("--state-db", help="Optional imported state_5.sqlite snapshot under /private/tmp")
    parser.add_argument("--history-db", help="Optional imported thread_history_1.sqlite snapshot under /private/tmp")
    parser.add_argument("--expected-id", action="append", default=[], help="Expected synthetic thread ID; repeatable")
    parser.add_argument("--read-id", action="append", default=[], help="Thread ID to inspect in detail; repeatable while thread/list still checks the full selected set")
    parser.add_argument("--resume-id", action="append", default=[], help="Interactive thread ID to resume without starting a turn; repeatable")
    parser.add_argument("--paginated-id", action="append", default=[], help="Paginated thread ID to read with includeTurns=true; repeatable")
    parser.add_argument("--codex", default=None, help="Installed codex executable; defaults to PATH")
    parser.add_argument(
        "--preflight",
        action="store_true",
        help="Report state database path coverage without starting app-server or repairing an index",
    )
    parser.add_argument("--work-root", help="Private temporary parent under /private/tmp")
    parser.add_argument("--keep-work-root", action="store_true", help="Keep the neutral test homes for inspection")
    parser.add_argument("--timeout", type=float, default=15.0, help="Per-RPC timeout in seconds")
    parser.add_argument("--max-response-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--page-size", type=int, default=500)
    parser.add_argument("--max-threads", type=int, default=10_000)
    return parser.parse_args()


def run() -> dict[str, Any]:
    args = parse_arguments()
    if args.timeout <= 0 or args.page_size <= 0 or args.max_threads <= 0 or args.max_response_bytes <= 0:
        raise VerificationError("bounds must be positive")
    source_root = private_path(args.transcript_root, "transcript root")
    selected_history_directories(source_root)
    account_home = private_path(args.account_home, "account home") if args.account_home else None
    state_arg = private_path(args.state_db, "state database") if args.state_db else None
    history_arg = private_path(args.history_db, "history database") if args.history_db else None
    state_source = state_arg or next((source_root / name for name in ("state_5.sqlite",) if (source_root / name).is_file()), None)
    history_source = history_arg or next((source_root / name for name in ("thread_history_1.sqlite",) if (source_root / name).is_file()), None)
    if state_source is not None:
        state_source = private_path(str(state_source), "state database")
    if history_source is not None:
        history_source = private_path(str(history_source), "history database")
    if state_source is not None and account_home is None:
        raise VerificationError("--account-home is required with an imported state database")
    if state_source is None and (account_home is not None or history_source is not None):
        raise VerificationError("--account-home and --history-db require an imported state database")

    if args.preflight:
        if state_source is None:
            raise VerificationError("--preflight requires a state_5.sqlite snapshot")
        if args.expected_id or args.read_id or args.resume_id or args.paginated_id:
            raise VerificationError("--preflight reports all state rows; omit thread selectors")
        assert account_home is not None
        return preflight_state(state_source, source_root, account_home, history_source, args.max_threads)

    state_preflight: dict[str, Any] | None = None
    if state_source is not None:
        assert account_home is not None
        state_preflight = preflight_state(state_source, source_root, account_home, history_source, args.max_threads)
        if not state_preflight["preflight_ok"]:
            raise VerificationError("the active state database contains unresolved or escaping rollout paths")

    expected_ids = set(args.expected_id)
    if len(expected_ids) != len(args.expected_id):
        raise VerificationError("expected thread IDs must be unique")
    records = (
        read_state_records(
            state_source,
            source_root,
            account_home,
            expected_ids,
            args.max_threads,
        )
        if state_source is not None
        else scan_fixture_records(source_root, args.max_threads)
    )
    if expected_ids and {record.thread_id for record in records} != expected_ids:
        raise VerificationError("expected thread IDs were not all found")
    record_ids = {record.thread_id for record in records}
    read_ids = set(args.read_id) if args.read_id else (record_ids if state_source is None else set())
    if len(read_ids) != len(args.read_id) and args.read_id:
        raise VerificationError("read thread IDs must be unique")
    if not read_ids.issubset(record_ids):
        raise VerificationError("a requested detailed-read thread is not in the selected imported set")
    resume_ids = set(args.resume_id)
    if len(resume_ids) != len(args.resume_id):
        raise VerificationError("resume thread IDs must be unique")
    if not resume_ids.issubset(record_ids):
        raise VerificationError("a requested resume thread is not in the selected imported set")
    if state_source is not None and not (read_ids and resume_ids):
        raise VerificationError("imported state verification requires at least one --read-id and --resume-id")
    paginated_ids = [record.thread_id for record in records if record.history_mode.lower() == "paginated"]
    paginated_read_ids = set(args.paginated_id)
    if len(paginated_read_ids) != len(args.paginated_id):
        raise VerificationError("paginated thread IDs must be unique")
    if not paginated_read_ids.issubset(set(paginated_ids)):
        raise VerificationError("paginated thread ID is not in the selected imported set")
    if not paginated_read_ids and history_source is not None and paginated_ids and state_source is None:
        paginated_read_ids = {paginated_ids[0]}
    if not paginated_read_ids and history_source is not None and paginated_ids and state_source is not None:
        raise VerificationError("imported paginated history verification requires --paginated-id from the interactive list")
    if history_source is not None and not paginated_ids:
        raise VerificationError("history database supplied but no paginated thread was selected")
    if paginated_ids and history_source is None:
        raise VerificationError("paginated threads require --history-db for an explicit read check")

    requested_codex = args.codex or shutil.which("codex")
    if requested_codex is None:
        raise VerificationError("codex executable was not found")
    codex = str(Path(requested_codex).resolve())
    if not os.access(codex, os.X_OK):
        raise VerificationError("codex executable is not executable")

    parent_root: Path
    if args.work_root:
        parent_root = private_path(args.work_root, "work root", must_exist=False)
        parent_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    else:
        parent_root = PRIVATE_TMP
    run_root = Path(tempfile.mkdtemp(prefix="ai-manager-history-verify-", dir=str(parent_root)))
    try:
        home_a = run_root / "home-a"
        home_b = run_root / "home-b"
        codex_a = run_root / "codex-a"
        codex_b = run_root / "codex-b"
        env_a = prepare_home(
            home_a,
            codex_a,
            source_root,
            state_source,
            history_source,
            codex,
            args.timeout,
            args.max_response_bytes,
        )
        env_b = prepare_home(
            home_b,
            codex_b,
            source_root,
            state_source,
            history_source,
            codex,
            args.timeout,
            args.max_response_bytes,
        )
        initial_a, reads_a, paginated_a, resumes_a = verify_home(
            codex, env_a, records, args.timeout, args.max_response_bytes, args.page_size, args.max_threads, paginated_read_ids, read_ids,
            state_db_only=state_source is not None,
            resume_ids=resume_ids,
            require_all_expected=state_source is None,
        )
        initial_b, reads_b, paginated_b, resumes_b = verify_home(
            codex, env_b, records, args.timeout, args.max_response_bytes, args.page_size, args.max_threads, paginated_read_ids, read_ids,
            state_db_only=state_source is not None,
            resume_ids=resume_ids,
            require_all_expected=state_source is None,
        )
        expected = {record.thread_id for record in records}
        if initial_a != initial_b:
            raise VerificationError("the two neutral homes did not list the same interactive imported IDs")

        later_listed = verify_native_later_discovery(
            run_root,
            codex,
            args.timeout,
            args.max_response_bytes,
            args.page_size,
            args.max_threads,
        )

        if history_source is None:
            print("LIMITATION: no thread_history_1.sqlite snapshot was supplied; paginated history was not checked.", file=sys.stderr)
        return {
            "ok": True,
            "active_state_thread_count": len(expected),
            "home_a_initial_listed_count": len(initial_a),
            "home_b_initial_listed_count": len(initial_b),
            "background_or_noninteractive_count": len(expected - initial_a),
            "same_initial_id_set": initial_a == initial_b,
            "home_a_initial_read_count": reads_a,
            "home_b_initial_read_count": reads_b,
            "detailed_read_requested_count": len(read_ids),
            "home_a_resume_count": resumes_a,
            "home_b_resume_count": resumes_b,
            "resume_requested_count": len(resume_ids),
            "later_thread_listed_in_both": later_listed,
            "later_thread_discovered_without_sql_insertion": later_listed,
            "product_state_copied_without_row_changes": state_source is not None,
            "active_state_paths_preflight_ok": state_preflight is None or state_preflight["preflight_ok"],
            "paginated_database_supplied": history_source is not None,
            "paginated_thread_count": len(paginated_ids),
            "paginated_read_verified_in_both": paginated_a and paginated_b,
        }
    finally:
        if args.keep_work_root:
            print("LIMITATION: neutral work root retained under /private/tmp.", file=sys.stderr)
        else:
            shutil.rmtree(run_root, ignore_errors=True)


def main() -> int:
    try:
        summary = run()
    except VerificationError as error:
        print(f"verify-codex-history: {error}", file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(f"verify-codex-history: bounded local check failed ({type(error).__name__})", file=sys.stderr)
        return 1
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    if summary.get("preflight") and not summary.get("preflight_ok"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
