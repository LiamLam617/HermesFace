#!/usr/bin/env python3
"""
HermesFace runtime runner for Hugging Face Spaces with Storage Buckets.

This script treats /opt/data as the durable state directory. It bootstraps the
Hermes config, points Hermes at the local 9Router OpenAI-compatible API, patches
the dashboard for HF iframe embedding, and manages dashboard/gateway processes.
"""

from __future__ import annotations

import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Any


HERMES_DATA = Path(os.environ.get("HERMES_HOME", "/opt/data"))
APP_DIR = Path(os.environ.get("HERMES_APP_DIR", "/opt/hermes"))
AGENT_NAME = os.environ.get("AGENT_NAME", "HermesFace")
NINEROUTER_BASE_URL = "http://localhost:20128/v1"
DEFAULT_MODEL = os.environ.get("NINEROUTER_DEFAULT_MODEL", "kr/claude-sonnet-4.5")
DEFAULT_API_KEY = os.environ.get("NINEROUTER_API_KEY", "sk-local")

_gateway_proc: subprocess.Popen[str] | None = None


class TeeLogger:
    """Duplicate stdout/stderr into /opt/data/logs without hiding terminal logs."""

    def __init__(self, filename: Path, stream: Any):
        self.stream = stream
        self.file = filename.open("a", encoding="utf-8")

    def write(self, message: str) -> None:
        self.stream.write(message)
        self.file.write(message)
        self.flush()

    def flush(self) -> None:
        self.stream.flush()
        self.file.flush()

    def fileno(self) -> int:
        return self.stream.fileno()


def _load_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}

    text = path.read_text(encoding="utf-8")
    if not text.strip():
        return {}

    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text)
        return data if isinstance(data, dict) else {}
    except ModuleNotFoundError:
        return _load_simple_yaml(text)


def _load_simple_yaml(text: str) -> dict[str, Any]:
    """Tiny two-level YAML reader for local tests when PyYAML is unavailable."""
    data: dict[str, Any] = {}
    current: dict[str, Any] | None = None
    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        if not raw_line.startswith(" "):
            key, _, value = raw_line.partition(":")
            key = key.strip()
            value = value.strip()
            if value:
                data[key] = value
                current = None
            else:
                current = {}
                data[key] = current
        elif current is not None:
            key, _, value = raw_line.strip().partition(":")
            current[key.strip()] = value.strip()
    return data


def _dump_yaml(path: Path, data: dict[str, Any]) -> None:
    try:
        import yaml  # type: ignore

        rendered = yaml.safe_dump(data, sort_keys=False, default_flow_style=False, allow_unicode=True)
    except ModuleNotFoundError:
        rendered = _dump_simple_yaml(data)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(rendered, encoding="utf-8")


def _dump_simple_yaml(data: dict[str, Any], indent: int = 0) -> str:
    lines: list[str] = []
    prefix = " " * indent
    for key, value in data.items():
        if isinstance(value, dict):
            lines.append(f"{prefix}{key}:")
            lines.append(_dump_simple_yaml(value, indent + 2).rstrip())
        else:
            lines.append(f"{prefix}{key}: {value}")
    return "\n".join(lines) + "\n"


def ensure_state_dirs(data_dir: Path) -> None:
    for name in (
        "9router-data",
        "cron",
        "sessions",
        "logs",
        "hooks",
        "memories",
        "skills",
        "skins",
        "plans",
        "workspace",
        "home",
    ):
        (data_dir / name).mkdir(parents=True, exist_ok=True)


def ensure_default_config(data_dir: Path, app_dir: Path, agent_name: str) -> None:
    ensure_state_dirs(data_dir)

    config_path = data_dir / "config.yaml"
    if not config_path.exists():
        template = app_dir / "cli-config.yaml.example"
        if template.exists():
            shutil.copy2(str(template), str(config_path))
            print("[runner] Created config.yaml from Hermes template")
        else:
            _dump_yaml(
                config_path,
                {
                    "agent": {"name": agent_name},
                    "server": {"host": "0.0.0.0", "port": 7860},
                },
            )
            print("[runner] Created minimal config.yaml")

    env_path = data_dir / ".env"
    if not env_path.exists():
        template = app_dir / ".env.example"
        if template.exists():
            shutil.copy2(str(template), str(env_path))
            print("[runner] Created .env from Hermes template")
        else:
            env_path.write_text("", encoding="utf-8")
            print("[runner] Created empty .env")

    soul_path = data_dir / "SOUL.md"
    if not soul_path.exists():
        template = app_dir / "docker" / "SOUL.md"
        if template.exists():
            shutil.copy2(str(template), str(soul_path))
            print("[runner] Created SOUL.md from Hermes template")
        else:
            soul_path.write_text(
                f"# {agent_name}\n\n"
                f"I am {agent_name}, a self-improving AI assistant powered by Hermes Agent.\n",
                encoding="utf-8",
            )
            print("[runner] Created default SOUL.md")


def configure_ninerouter_model(config_path: Path, default_model: str, api_key: str) -> None:
    config = _load_yaml(config_path)
    config.pop("provider", None)
    config.pop("openai_compatible", None)

    model = config.get("model")
    if not isinstance(model, dict):
        model = {}
        config["model"] = model

    model["provider"] = "custom"
    model["default"] = default_model
    model["base_url"] = NINEROUTER_BASE_URL
    model["api_key"] = api_key

    _dump_yaml(config_path, config)
    print(f"[runner] Hermes model configured for 9Router ({default_model})")


def patch_web_server_cors(app_dir: Path) -> bool:
    web_server = app_dir / "hermes_cli" / "web_server.py"
    if not web_server.exists():
        return False

    try:
        code = web_server.read_text(encoding="utf-8")
        original = code

        cors_patterns = (
            'allow_origin_regex=r"^https?://(localhost|127\\\\.0\\\\.0\\\\.1)(:\\\\d+)?$"',
            'allow_origin_regex=r"^https?://(localhost|127\\.0\\.0\\.1)(:\\d+)?$"',
        )
        for pattern in cors_patterns:
            code = code.replace(pattern, 'allow_origins=["*"]')

        for pattern in ('X-Frame-Options", "DENY"', 'X-Frame-Options", "SAMEORIGIN"'):
            code = code.replace(pattern, 'X-Frame-Options", "ALLOWALL"')

        code = code.replace(
            "frame-ancestors 'none'",
            "frame-ancestors 'self' https://huggingface.co https://*.hf.space",
        )

        if code != original:
            web_server.write_text(code, encoding="utf-8")
            print("[runner] Patched Hermes dashboard CORS/frame headers for HF Spaces")
            return True
    except Exception as exc:
        print(f"[runner] web_server patch failed (non-fatal): {exc}")

    return False


def build_hermes_env(data_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["HERMES_HOME"] = str(data_dir)
    env["GATEWAY_ALLOW_ALL_USERS"] = "true"
    env.pop("API_SERVER_ENABLED", None)
    env.pop("API_SERVER_PORT", None)
    return env


def _start_process(cmd: list[str], label: str, env: dict[str, str], log_path: Path) -> subprocess.Popen[str] | None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_fh = log_path.open("a", encoding="utf-8")
    try:
        process = subprocess.Popen(
            cmd,
            cwd=str(APP_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )

        def copy_output() -> None:
            try:
                assert process.stdout is not None
                for line in process.stdout:
                    log_fh.write(line)
                    log_fh.flush()
                    stripped = line.strip()
                    if not stripped:
                        continue
                    if any(
                        skip in stripped
                        for skip in (
                            "Downloading",
                            "Fetching",
                            "%|",
                            "Already cached",
                            "Using cache",
                            "tokenizer",
                            ".safetensors",
                            "model-",
                            "shard",
                        )
                    ):
                        continue
                    print(line, end="")
            except Exception as exc:
                print(f"[runner] {label} output error: {exc}")
            finally:
                log_fh.close()

        threading.Thread(target=copy_output, daemon=True).start()
        print(f"[runner] {label} started (PID {process.pid})")
        return process
    except Exception as exc:
        log_fh.close()
        print(f"[runner] ERROR starting {label}: {exc}")
        traceback.print_exc()
        return None


def _wait_for_port(host: str, port: int, timeout: int = 15, label: str = "service") -> bool:
    """Poll until a TCP port is accepting connections or timeout expires."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                print(f"[runner] {label} ready on port {port}")
                return True
        except (ConnectionRefusedError, OSError):
            time.sleep(0.5)
    print(f"[runner] WARNING: {label} did not bind port {port} within {timeout}s")
    return False


def run_hermes() -> subprocess.Popen[str] | None:
    if not APP_DIR.exists():
        print(f"[runner] ERROR: Hermes app directory does not exist: {APP_DIR}")
        return None

    hermes_bin = shutil.which("hermes") or str(APP_DIR / ".venv" / "bin" / "hermes")
    if not Path(hermes_bin).exists():
        print("[runner] ERROR: hermes CLI not found")
        return None

    ensure_default_config(HERMES_DATA, APP_DIR, AGENT_NAME)
    configure_ninerouter_model(HERMES_DATA / "config.yaml", DEFAULT_MODEL, DEFAULT_API_KEY)
    patch_web_server_cors(APP_DIR)

    env = build_hermes_env(HERMES_DATA)
    log_dir = HERMES_DATA / "logs"

    dashboard_cmd = [
        hermes_bin,
        "dashboard",
        "--host",
        "0.0.0.0",
        "--port",
        "7860",
        "--no-open",
        "--insecure",
    ]
    print("[runner] Starting Hermes dashboard on port 7860...")
    dashboard_proc = _start_process(dashboard_cmd, "Dashboard", env, log_dir / "dashboard.log")

    # 等待 Dashboard 就緒，而非固定 sleep
    _wait_for_port("127.0.0.1", 7860, timeout=15, label="Dashboard")

    print("[runner] Starting Hermes gateway...")
    gateway_cmd = [hermes_bin, "gateway"]
    global _gateway_proc
    _gateway_proc = _start_process(gateway_cmd, "Gateway", env, log_dir / "gateway.log")

    return dashboard_proc


def setup_logging(data_dir: Path) -> None:
    log_dir = data_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    sys.stdout = TeeLogger(log_dir / "runner.log", sys.stdout)
    sys.stderr = sys.stdout


def main() -> int:
    setup_logging(HERMES_DATA)
    process: subprocess.Popen[str] | None = None
    try:
        process = run_hermes()
        if process is None:
            return 1

        def handle_signal(sig: int, _frame: Any) -> None:
            print(f"\n[runner] Signal {sig} received. Shutting down...")
            if _gateway_proc:
                _gateway_proc.terminate()
                try:
                    _gateway_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    _gateway_proc.kill()
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
            raise SystemExit(0)

        signal.signal(signal.SIGINT, handle_signal)
        signal.signal(signal.SIGTERM, handle_signal)

        exit_code = process.wait()
        print(f"[runner] Hermes dashboard exited with code {exit_code}")
        return exit_code
    except Exception as exc:
        print(f"[runner] FATAL ERROR: {exc}")
        traceback.print_exc()
        if process:
            process.terminate()
        return 1


if __name__ == "__main__":
    sys.exit(main())
