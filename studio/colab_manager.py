"""Colab OAuth bridge, G4-safe runtime allocator, read-only attach probe, deploy & cmd runner."""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

from .config_store import (
    CONFIG_DIR,
    REPO_ROOT,
    ConfigStore,
    LogBroker,
    MODES_BY_ID,
    mask_url,
    resolve_mode_env,
)
from .engine_proxy import EngineProxyServer, fetch_engine_telemetry

SINGLE_SHAPE_GPUS = frozenset({"g4", "h100", "l4"})
HIGH_MEM_GPUS = frozenset({"a100"})
SUPPORTED_GPUS = frozenset({"g4", "a100", "h100", "l4", "t4"})

PROBE_MARKER = "STUDIO_PROBE_JSON:"
BRIDGE_MARKER = "STUDIO_BRIDGE_JSON:"
TUNNEL_URL_RE = re.compile(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com")

_BRIDGE_HELPER_SCRIPT = r'''
import json, os, sys, time, urllib.request, uuid
from importlib import resources

def _sync_proxies():
    try:
        proxies = urllib.request.getproxies()
        for k in ("http", "https"):
            if proxies.get(k):
                os.environ.setdefault(f"{k}_proxy", proxies[k])
                os.environ.setdefault(f"{k.upper()}_PROXY", proxies[k])
    except Exception:
        pass
    os.environ.setdefault("NO_PROXY", "127.0.0.1,localhost")
    os.environ.setdefault("no_proxy", "127.0.0.1,localhost")

_sync_proxies()

import requests
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow

from colab_cli.auth import PUBLIC_SCOPES, TOKEN_CONFIG_PATH, REMOTE_REDIRECT_URI
from colab_cli.common import state
from colab_cli.client import Accelerator, Variant, Shape, resolve_assign_shape, PostAssignmentResponse, ColabRequestError
from colab_cli.state import SessionState

PKCE_VERIFIER_PATH = os.path.expanduser("~/.config/colab-cli/pkce_verifier.txt")
ACCOUNT_PROFILE_CACHE_PATH = os.path.expanduser("~/.config/colab-cli/account_profile.json")
SINGLE_SHAPE_VALUES = frozenset({"G4", "H100", "L4"})

def emit(obj):
    print("STUDIO_BRIDGE_JSON:" + json.dumps(obj, ensure_ascii=False), flush=True)

def load_client_config():
    cfg_path = os.path.expanduser("~/.colab-cli-oauth-config.json")
    if os.path.exists(cfg_path):
        with open(cfg_path, "r", encoding="utf-8") as f:
            return json.load(f)
    res = resources.files("colab_cli").joinpath("oauth_config.json")
    return json.loads(res.read_text(encoding="utf-8"))

def has_valid_token():
    if not os.path.exists(TOKEN_CONFIG_PATH):
        return False
    try:
        creds = Credentials.from_authorized_user_file(TOKEN_CONFIG_PATH, PUBLIC_SCOPES)
        if creds and creds.valid:
            return True
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
            with open(TOKEN_CONFIG_PATH, "w", encoding="utf-8") as f:
                f.write(creds.to_json())
            return True
    except Exception:
        return False
    return False

def clear_local_session_store():
    try:
        existing = state.store.list()
        if isinstance(existing, list):
            for s in existing:
                state.store.remove(s.name)
        elif isinstance(existing, dict):
            for name in list(existing.keys()):
                state.store.remove(name)
    except Exception:
        pass
    state._client = None
    state._sessions = None

def get_account_email():
    if not os.path.exists(TOKEN_CONFIG_PATH):
        return ""
    try:
        creds = Credentials.from_authorized_user_file(TOKEN_CONFIG_PATH, PUBLIC_SCOPES)
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
            with open(TOKEN_CONFIG_PATH, "w", encoding="utf-8") as f:
                f.write(creds.to_json())
        tok_fp = (creds.refresh_token or creds.token or "")[-20:]
        if tok_fp and os.path.exists(ACCOUNT_PROFILE_CACHE_PATH):
            try:
                with open(ACCOUNT_PROFILE_CACHE_PATH, "r", encoding="utf-8") as cf:
                    cached = json.load(cf)
                if cached.get("fp") == tok_fp and cached.get("email"):
                    return str(cached["email"])
            except Exception:
                pass
        if creds and creds.token:
            r = requests.get(
                "https://www.googleapis.com/oauth2/v2/userinfo",
                headers={"Authorization": f"Bearer {creds.token}"},
                timeout=6,
            )
            if r.status_code == 200:
                email = str(r.json().get("email") or "").strip()
                if email and tok_fp:
                    os.makedirs(os.path.dirname(ACCOUNT_PROFILE_CACHE_PATH), exist_ok=True)
                    with open(ACCOUNT_PROFILE_CACHE_PATH, "w", encoding="utf-8") as cf:
                        json.dump({"fp": tok_fp, "email": email}, cf)
                return email
    except Exception:
        pass
    return ""

def safe_sync_sessions():
    for attempt in range(3):
        try:
            return state.sync_sessions()
        except Exception:
            if attempt == 2:
                cached = {s.name: s for s in state.store.list()}
                return cached, []
            time.sleep(1.0)

def cmd_auth_status():
    if not has_valid_token():
        emit({"ok": True, "logged_in": False, "email": "", "paid_balance": None, "burn_rate_hourly": None, "active_assignments": 0, "sessions": []})
        return
    try:
        info = state.client.get_consumption_user_info()
        local_sessions, assignments = safe_sync_sessions()
        name_by_ep = {s.endpoint: s.name for s in local_sessions.values()}
        sess_list = []
        for a in assignments:
            sess_list.append({
                "name": name_by_ep.get(a.endpoint, "colab-vm"),
                "endpoint": a.endpoint,
                "accelerator": a.accelerator.value,
                "variant": a.variant.name,
                "shape": a.machine_shape.name,
            })
        emit({
            "ok": True,
            "logged_in": True,
            "email": get_account_email(),
            "paid_balance": round(float(info.paid_compute_units_balance), 2),
            "burn_rate_hourly": round(float(info.consumption_rate_hourly), 2),
            "active_assignments": int(info.assignments_count),
            "sessions": sess_list,
        })
    except Exception as e:
        emit({"ok": False, "logged_in": True, "email": get_account_email(), "error": str(e), "sessions": []})

def cmd_auth_url():
    cfg = load_client_config()
    flow = InstalledAppFlow.from_client_config(cfg, PUBLIC_SCOPES)
    flow.redirect_uri = REMOTE_REDIRECT_URI
    auth_url, _ = flow.authorization_url(prompt="select_account consent", token_usage="remote")
    os.makedirs(os.path.dirname(PKCE_VERIFIER_PATH), mode=0o700, exist_ok=True)
    if getattr(flow, "code_verifier", None):
        with open(PKCE_VERIFIER_PATH, "w", encoding="utf-8") as f:
            f.write(flow.code_verifier)
        os.chmod(PKCE_VERIFIER_PATH, 0o600)
    emit({"ok": True, "auth_url": auth_url})

def cmd_auth_code(code_raw):
    try:
        cfg = load_client_config()
        flow = InstalledAppFlow.from_client_config(cfg, PUBLIC_SCOPES)
        flow.redirect_uri = REMOTE_REDIRECT_URI
        if os.path.exists(PKCE_VERIFIER_PATH):
            with open(PKCE_VERIFIER_PATH, "r", encoding="utf-8") as f:
                flow.code_verifier = f.read().strip()
        flow.fetch_token(code=code_raw.strip())
        creds = flow.credentials
        clear_local_session_store()
        for p in (ACCOUNT_PROFILE_CACHE_PATH, PKCE_VERIFIER_PATH):
            if os.path.exists(p):
                try:
                    os.remove(p)
                except Exception:
                    pass
        os.makedirs(os.path.dirname(TOKEN_CONFIG_PATH), mode=0o700, exist_ok=True)
        with open(TOKEN_CONFIG_PATH, "w", encoding="utf-8") as f:
            f.write(creds.to_json())
        os.chmod(TOKEN_CONFIG_PATH, 0o600)
        cmd_auth_status()
    except Exception as e:
        emit({"ok": False, "logged_in": False, "error": str(e)})

def cmd_auth_logout():
    clear_local_session_store()
    for p in (TOKEN_CONFIG_PATH, PKCE_VERIFIER_PATH, ACCOUNT_PROFILE_CACHE_PATH):
        if os.path.exists(p):
            try:
                os.remove(p)
            except Exception:
                pass
    emit({"ok": True, "logged_in": False, "email": ""})

def cmd_ensure_session(session_name, gpu_type):
    if not has_valid_token():
        emit({"ok": False, "error": "尚未登录 Google Colab CLI"})
        return
    gpu_norm = (gpu_type or "G4").strip().upper()
    accel_map = {
        "G4": Accelerator.G4,
        "A100": Accelerator.A100,
        "H100": Accelerator.H100,
        "L4": Accelerator.L4,
        "T4": Accelerator.T4,
    }
    accel = accel_map.get(gpu_norm, Accelerator.G4)
    local_sessions, assignments = safe_sync_sessions()
    target = local_sessions.get(session_name)
    if target is None and assignments:
        for a in assignments:
            if a.accelerator.value.upper() == accel.value.upper():
                target = SessionState(
                    name=session_name,
                    token=a.runtime_proxy_info.token,
                    url=a.runtime_proxy_info.url,
                    endpoint=a.endpoint,
                    token_expires_at=a.runtime_proxy_info.expires_at(),
                    variant=Variant.GPU.value,
                    accelerator=a.accelerator.value,
                    machine_shape=Shape.HIGH_RAM.name if a.machine_shape == Shape.HIGH_RAM else Shape.STANDARD.name,
                )
                state.store.add(target)
                break
    if target is not None and (target.accelerator or "").strip().upper() == accel.value.upper():
        base = target.url.rstrip("/")
        hdrs = {
            "Accept": "application/json",
            "X-Colab-Client-Agent": "colab-cli",
            "X-Colab-Runtime-Proxy-Token": target.token,
            "Authorization": f"Bearer {target.token}",
        }
        try:
            r = requests.get(f"{base}/api/kernels", headers=hdrs, params={"authuser": "0", "colab-runtime-proxy-token": target.token}, timeout=8)
            if r.status_code == 200:
                emit({"ok": True, "reused": True, "session": session_name, "accelerator": target.accelerator})
                return
        except Exception:
            pass

    if target is not None:
        try:
            state.client.unassign(target.endpoint)
        except Exception:
            pass
        try:
            state.prune_session(target.name)
        except Exception:
            pass

    # Hard guard: SINGLE_SHAPE_GPUS (G4, H100, L4) must NEVER send Shape.HIGH_RAM
    if accel.value.upper() in SINGLE_SHAPE_VALUES:
        shape = None
    elif accel == Accelerator.A100:
        shape = resolve_assign_shape(accel, high_mem=True)
    else:
        shape = None

    try:
        res = state.client.assign(uuid.uuid4(), variant=Variant.GPU, accelerator=accel, shape=shape)
    except ColabRequestError as req_err:
        if shape is not None and getattr(getattr(req_err, "response", None), "status_code", None) == 400:
            shape = None
            res = state.client.assign(uuid.uuid4(), variant=Variant.GPU, accelerator=accel, shape=None)
        else:
            emit({"ok": False, "error": str(req_err)})
            return

    if isinstance(res, PostAssignmentResponse):
        token = res.runtime_proxy_info.token
        url = res.runtime_proxy_info.url
        endpoint = res.endpoint
        exp = res.runtime_proxy_info.expires_at()
    else:
        token = res.runtime_proxy_info.token if hasattr(res, "runtime_proxy_info") else getattr(res, "runtime_proxy_token", "")
        url = res.runtime_proxy_info.url if hasattr(res, "runtime_proxy_info") else ""
        endpoint = res.endpoint
        exp = res.runtime_proxy_info.expires_at() if hasattr(res, "runtime_proxy_info") else None

    s = SessionState(
        name=session_name,
        token=token,
        url=url,
        endpoint=endpoint,
        token_expires_at=exp,
        variant=Variant.GPU.value,
        accelerator=accel.value,
        machine_shape=Shape.HIGH_RAM.name if shape == Shape.HIGH_RAM else Shape.STANDARD.name,
    )
    state.store.add(s)

    base = s.url.rstrip("/")
    hdrs = {
        "Accept": "application/json",
        "X-Colab-Client-Agent": "colab-cli",
        "X-Colab-Runtime-Proxy-Token": s.token,
        "Authorization": f"Bearer {s.token}",
    }
    deadline = time.time() + 50
    while time.time() < deadline:
        try:
            r = requests.get(f"{base}/api/kernels", headers=hdrs, params={"authuser": "0", "colab-runtime-proxy-token": s.token}, timeout=6)
            if r.status_code == 200:
                break
        except Exception:
            pass
        time.sleep(2.0)
    emit({"ok": True, "reused": False, "session": session_name, "accelerator": accel.value})

def cmd_stop_session(session_name):
    if not has_valid_token():
        emit({"ok": False, "error": "尚未登录 Google Colab CLI"})
        return
    try:
        local_sessions, assignments = safe_sync_sessions()
        stopped = 0
        s = local_sessions.get(session_name)
        if s is not None:
            try:
                state.client.unassign(s.endpoint)
                stopped += 1
            except Exception:
                pass
            try:
                state.store.remove(s.name)
            except Exception:
                pass
        elif assignments:
            for a in assignments:
                try:
                    state.client.unassign(a.endpoint)
                    stopped += 1
                except Exception:
                    pass
        emit({"ok": True, "stopped_count": stopped, "session": session_name})
    except Exception as e:
        emit({"ok": False, "error": str(e)})

cmd = sys.argv[1]
if cmd == "auth_status":
    cmd_auth_status()
elif cmd == "auth_url":
    cmd_auth_url()
elif cmd == "auth_code":
    cmd_auth_code(sys.argv[2])
elif cmd == "auth_logout":
    cmd_auth_logout()
elif cmd == "ensure_session":
    cmd_ensure_session(sys.argv[2], sys.argv[3])
elif cmd == "stop_session":
    cmd_stop_session(sys.argv[2])
'''

_REMOTE_ATTACH_PROBE_PY = r'''
import glob, json, os, re, shutil, subprocess, urllib.request

result = {
    "gpu_name": "",
    "processes": {
        "maya_alive": False,
        "strata_alive": False,
        "cloudflared_alive": False,
        "hf_ro_fuse_alive": False,
        "gcsfuse_alive": False,
        "engine_alive": False,
    },
    "mounts": {
        "hf_fuse": False,
        "gcsfuse": False,
        "local_scratch": False,
    },
    "tunnel_url": "",
    "local_health": None,
    "maya_log_tail": [],
}

try:
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=8,
    )
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if lines:
        result["gpu_name"] = lines[0]
except Exception:
    pass

try:
    for ent in os.listdir("/proc"):
        if not ent.isdigit():
            continue
        try:
            raw = open(f"/proc/{ent}/cmdline", "rb").read()
        except Exception:
            continue
        if not raw:
            continue
        cmd = " ".join(a.decode("utf-8", "ignore") for a in raw.split(b"\x00") if a)
        if not cmd:
            continue
        if ("maya.py" in cmd or "maya-ds4" in cmd or "serve/server.py" in cmd) and "--engine strata" not in cmd:
            result["processes"]["maya_alive"] = True
        if "--engine strata" in cmd or re.search(r"(^|/|\s)strata(\s|$)", cmd):
            result["processes"]["strata_alive"] = True
        if "cloudflared" in cmd:
            result["processes"]["cloudflared_alive"] = True
        if "hf_ro_fuse" in cmd:
            result["processes"]["hf_ro_fuse_alive"] = True
        if "gcsfuse" in cmd:
            result["processes"]["gcsfuse_alive"] = True
except Exception:
    pass

result["processes"]["engine_alive"] = bool(
    result["processes"]["maya_alive"] or result["processes"]["strata_alive"]
)

mount_points = set()
try:
    with open("/proc/mounts", "r", encoding="utf-8", errors="replace") as mf:
        for ln in mf:
            parts = ln.split()
            if len(parts) >= 2:
                mount_points.add(parts[1])
except Exception:
    pass

result["mounts"]["hf_fuse"] = ("/mnt/hf" in mount_points) or os.path.ismount("/mnt/hf")
result["mounts"]["gcsfuse"] = ("/mnt/gcs" in mount_points) or os.path.ismount("/mnt/gcs")
scratch_ok = ("/mnt/local-scratch" in mount_points) or os.path.isdir("/mnt/local-scratch")
result["mounts"]["local_scratch"] = scratch_ok
if scratch_ok:
    try:
        result["mounts"]["scratch_free"] = f"{round(shutil.disk_usage('/mnt/local-scratch').free / (1024**3), 1)} GB"
    except Exception:
        pass
try:
    result["mounts"]["shm"] = f"{round(shutil.disk_usage('/dev/shm').total / (1024**3), 1)} GB"
except Exception:
    pass
try:
    result["mounts"]["root_free"] = f"{round(shutil.disk_usage('/').free / (1024**3), 1)} GB"
except Exception:
    pass

rx = re.compile(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com")
candidates = [
    "/content/project-maya/cloudflared.log",
    "/tmp/cloudflared.log",
    "/content/cloudflared.log",
]
for extra in sorted(glob.glob("/content/**/cloudflared*.log", recursive=True)):
    if extra not in candidates:
        candidates.append(extra)
found_urls = []
for log_file in candidates:
    if os.path.isfile(log_file):
        try:
            txt = open(log_file, "r", encoding="utf-8", errors="replace").read()
            found_urls.extend(rx.findall(txt))
        except Exception:
            pass
if found_urls:
    result["tunnel_url"] = found_urls[-1]

for port in (8000, 18181):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2.5) as resp:
            if resp.status == 200:
                result["local_health"] = json.loads(resp.read().decode("utf-8", "replace"))
                break
    except Exception:
        pass

if os.path.isfile("/content/project-maya/maya-ds4.log"):
    try:
        with open("/content/project-maya/maya-ds4.log", "r", encoding="utf-8", errors="replace") as mf:
            result["maya_log_tail"] = [ln.rstrip() for ln in mf.readlines()[-30:]]
    except Exception:
        pass

print("STUDIO_PROBE_JSON:" + json.dumps(result, ensure_ascii=False))
'''


def _sync_macos_system_proxies_to_env() -> None:
    """Sync macOS/OS proxy configuration into process env for Colab & HTTPS requests."""
    try:
        proxies = urllib.request.getproxies()
        for k in ("http", "https"):
            val = proxies.get(k)
            if val:
                os.environ.setdefault(f"{k}_proxy", val)
                os.environ.setdefault(f"{k.upper()}_PROXY", val)
    except Exception:
        pass
    os.environ.setdefault("NO_PROXY", "127.0.0.1,localhost")
    os.environ.setdefault("no_proxy", "127.0.0.1,localhost")


def _extract_marked_json(stdout: str, marker: str) -> dict[str, Any] | None:
    """Extract JSON payload emitted after a line marker, falling back to last JSON object line."""
    for line in reversed((stdout or "").splitlines()):
        s = line.strip()
        if marker in s:
            raw = s.split(marker, 1)[1].strip()
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, dict):
                    return parsed
            except json.JSONDecodeError:
                pass
    for line in reversed((stdout or "").splitlines()):
        s = line.strip()
        if s.startswith("{") and s.endswith("}"):
            try:
                parsed = json.loads(s)
                if isinstance(parsed, dict):
                    return parsed
            except json.JSONDecodeError:
                pass
    return None


def _python_has_colab_cli(py_bin: str) -> bool:
    if not py_bin or not os.path.isfile(py_bin):
        return False
    try:
        r = subprocess.run(
            [py_bin, "-c", "import colab_cli"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.returncode == 0
    except Exception:
        return False


def _discover_colab_toolchain() -> tuple[str | None, str | None]:
    """Locate `colab` CLI binary and a Python interpreter capable of importing `colab_cli`."""
    candidates = [
        shutil.which("colab"),
        str(Path.home() / ".local" / "bin" / "colab"),
        "/opt/homebrew/bin/colab",
        "/usr/local/bin/colab",
    ]
    colab_bin: str | None = None
    for cand in candidates:
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            colab_bin = cand
            break

    colab_python: str | None = None
    if _python_has_colab_cli(sys.executable):
        colab_python = sys.executable

    if colab_python is None and colab_bin is not None:
        try:
            with open(colab_bin, "r", encoding="utf-8", errors="ignore") as fh:
                first_line = fh.readline().strip()
            if first_line.startswith("#!"):
                shebang = first_line[2:].strip().split()
                if shebang:
                    py_cand = shebang[1] if shebang[0].endswith("/env") and len(shebang) > 1 else shebang[0]
                    if _python_has_colab_cli(py_cand):
                        colab_python = py_cand
        except OSError:
            pass

    if colab_python is None:
        uv_py = Path.home() / ".local" / "share" / "uv" / "tools" / "google-colab-cli" / "bin" / "python"
        if _python_has_colab_cli(str(uv_py)):
            colab_python = str(uv_py)

    return colab_bin, colab_python


def _fmt_duration(seconds: float) -> str:
    sec = max(0, int(round(seconds)))
    if sec < 60:
        return f"{max(1, sec)}s"
    if sec < 3600:
        m, s = divmod(sec, 60)
        return f"{m}m {s:02d}s"
    h, rem = divmod(sec, 3600)
    return f"{h}h {rem // 60:02d}m"


def _parse_maya_warmup_lines(lines: list[str], ram_track: dict[str, float]) -> dict[str, Any] | None:
    """Parse latest VRAM/RAM expert loading or initialization progress from maya-ds4.log."""
    for ln in reversed(lines):
        s = (ln or "").strip()
        if not s:
            continue
        m_ram = re.search(r"ds4:\s*copying experts\s*(\d+)\s*/\s*(\d+)\s*\(([^)]+)\)", s)
        if m_ram:
            x = int(m_ram.group(1))
            y = max(1, int(m_ram.group(2)))
            info = m_ram.group(3)
            frac = min(1.0, x / y)
            pct = round(74.0 + 25.0 * frac, 1)
            sub_pct = round(100.0 * frac, 1)
            now = time.monotonic()
            if "x0" not in ram_track:
                ram_track["x0"] = float(x)
                ram_track["t0"] = now
            dt = now - ram_track.get("t0", now)
            dx = x - ram_track.get("x0", float(x))
            if dx > 0 and dt > 3.0:
                rate = dx / dt
                rem_s = max(5.0, (y - x) / rate + 15.0)
            else:
                rem_s = max(10.0, (1.0 - frac) * 620.0 + 15.0)
            return {
                "percent": pct,
                "sub_percent": sub_pct,
                "label": f"正在装入 RAM 专家权重 ({sub_pct:.0f}%)",
                "detail": f"RAM 专家: {x:,} / {y:,} ({info})",
                "eta_text": f"预计剩余 ~{_fmt_duration(rem_s)}",
            }

        m_vram = re.search(r"ds4:\s*experts\s*(\d+)\s*/\s*(\d+)\s*\(([^)]+)\)", s)
        if m_vram:
            x = int(m_vram.group(1))
            y = max(1, int(m_vram.group(2)))
            info = m_vram.group(3)
            frac = min(1.0, x / y)
            pct = round(59.0 + 15.0 * frac, 1)
            sub_pct = round(100.0 * frac, 1)
            rem_s = max(15.0, (1.0 - frac) * 260.0 + 580.0)
            return {
                "percent": pct,
                "sub_percent": sub_pct,
                "label": f"正在装入 VRAM 专家权重 ({sub_pct:.0f}%)",
                "detail": f"VRAM 专家: {x:,} / {y:,} ({info})",
                "eta_text": f"VRAM 装入中 · 预计总剩余 ~{_fmt_duration(rem_s)}",
            }

        m_start = re.search(r"\[maya\]\s*still starting\s*\((\d+)\s*s\)", s)
        if m_start:
            sec = int(m_start.group(1))
            pct = round(min(58.8, 56.0 + sec / 65.0), 1)
            return {
                "percent": pct,
                "sub_percent": None,
                "label": f"引擎正在初始化与校验分片 ({sec}s)...",
                "detail": "校验 GGUF 索引并分配 96GB 显存空间",
                "eta_text": "权重装载阶段预计 ~14–18 分钟",
            }
    return None


def _is_health_ready(health: Any) -> bool:
    if not isinstance(health, dict) or not health:
        return False
    if bool(health.get("unloaded")):
        return False
    if isinstance(health.get("loaded"), bool):
        return bool(health["loaded"])
    if health.get("ok") is True:
        return True
    st = str(health.get("status") or "").strip().lower()
    return st in ("ok", "ready", "healthy", "loaded", "idle", "busy", "generating")


class ColabManager:
    """Coordinates Colab OAuth, G4-safe VM provisioning, non-destructive attach, keepalive & exec."""

    def __init__(
        self,
        config: ConfigStore,
        logs: LogBroker,
        proxy: EngineProxyServer,
        on_telemetry_refresh: Callable[[], dict[str, Any]] | None = None,
    ) -> None:
        _sync_macos_system_proxies_to_env()
        self.config = config
        self.logs = logs
        self.proxy = proxy
        self.on_telemetry_refresh = on_telemetry_refresh

        self._lock = threading.RLock()
        self.colab_bin, self.colab_python = _discover_colab_toolchain()

        self._colab_state: dict[str, Any] = {
            "logged_in": False,
            "email": "",
            "paid_balance": None,
            "burn_rate_hourly": None,
            "active_assignments": 0,
            "sessions": [],
            "keepalive_running": False,
            "selected_gpu": config.selected_gpu,
            "selected_session": config.selected_session,
            "gpu_name": "",
            "mounts": {},
        }
        self._deployment: dict[str, Any] = {
            "phase": "idle",
            "step_index": 0,
            "step_total": 6,
            "step_label": "",
            "percent": 0.0,
            "sub_percent": None,
            "detail": "",
            "eta_text": "",
            "started_at": None,
            "elapsed_sec": 0,
            "error": "",
        }
        self._deploy_thread: threading.Thread | None = None
        self._keepalive_proc: subprocess.Popen[str] | None = None
        self._keepalive_thread: threading.Thread | None = None
        self._keepalive_stop_ev = threading.Event()
        self._keepalive_session: str = config.selected_session

    def _build_subprocess_env(self) -> dict[str, str]:
        _sync_macos_system_proxies_to_env()
        env = os.environ.copy()
        extra_dirs = [
            str(Path.home() / ".local" / "bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        if self.colab_bin:
            extra_dirs.insert(0, str(Path(self.colab_bin).resolve().parent))
        cur_path = env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        parts = [d for d in extra_dirs if d] + [p for p in cur_path.split(":") if p]
        deduped: list[str] = []
        for p in parts:
            if p not in deduped:
                deduped.append(p)
        env["PATH"] = ":".join(deduped)
        env.setdefault("PYTHONIOENCODING", "utf-8")
        return env

    def _run_bounded(
        self,
        cmd: list[str],
        *,
        stdin_data: str | None = None,
        timeout: float = 45.0,
    ) -> tuple[int, str, str]:
        """Run a subprocess in its own session and kill its process group on timeout."""
        env = self._build_subprocess_env()
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE if stdin_data is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            start_new_session=True,
        )
        try:
            out, err = proc.communicate(stdin_data, timeout=timeout)
            return int(proc.returncode or 0), out or "", err or ""
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                proc.kill()
            out, err = proc.communicate()
            return 124, out or "", (err or "") + f"\nCommand timed out after {timeout}s"

    def _run_bridge(self, *args: str, timeout: float = 35.0) -> dict[str, Any] | None:
        if not self.colab_python:
            return None
        rc, out, err = self._run_bounded([self.colab_python, "-c", _BRIDGE_HELPER_SCRIPT, *args], timeout=timeout)
        parsed = _extract_marked_json(out, BRIDGE_MARKER)
        if parsed is not None:
            return parsed
        if rc != 0 and err.strip():
            return {"ok": False, "error": err.strip()[:400]}
        return None

    def _find_keepalive_pids(self, session: str = "") -> tuple[list[int], list[int]]:
        """Return (external_pids, studio_pids) of running keepalive_colab.sh processes."""
        studio_pids: list[int] = []
        if self._keepalive_proc is not None and self._keepalive_proc.poll() is None:
            studio_pids.append(self._keepalive_proc.pid)
        if self._keepalive_thread is not None and self._keepalive_thread.is_alive():
            studio_pids.append(os.getpid())

        external_pids: list[int] = []
        pgrep_cmd = ["pgrep", "-fl", "keepalive_colab.sh"] if sys.platform == "darwin" else ["pgrep", "-af", "keepalive_colab.sh"]
        try:
            r = subprocess.run(pgrep_cmd, capture_output=True, text=True, timeout=3)
            if r.returncode != 0:
                r = subprocess.run(["pgrep", "-f", "keepalive_colab.sh"], capture_output=True, text=True, timeout=3)
            if r.returncode == 0 and r.stdout:
                for line in r.stdout.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    parts = line.split(None, 1)
                    if not parts[0].isdigit():
                        continue
                    pid = int(parts[0])
                    cmdline = parts[1] if len(parts) > 1 else ""
                    if pid == os.getpid() or pid in studio_pids:
                        continue
                    if cmdline and ("pgrep" in cmdline or "keepalive_colab.sh" not in cmdline):
                        continue
                    if session and cmdline and session not in cmdline:
                        continue
                    external_pids.append(pid)
        except Exception:
            pass
        return external_pids, studio_pids

    def is_keepalive_running(self, session: str = "") -> bool:
        ext, stu = self._find_keepalive_pids(session)
        return bool(ext or stu)

    def get_colab_snapshot(self) -> dict[str, Any]:
        with self._lock:
            snap = dict(self._colab_state)
            snap["selected_gpu"] = self.config.selected_gpu
            snap["selected_session"] = self.config.selected_session
            snap["keepalive_running"] = self.is_keepalive_running(self.config.selected_session)
            return snap

    def get_deployment_snapshot(self) -> dict[str, Any]:
        with self._lock:
            snap = dict(self._deployment)
            started_at = snap.get("started_at")
            phase = str(snap.get("phase") or "idle")
            if started_at is not None and phase not in ("idle", "ready", "error"):
                snap["elapsed_sec"] = int(max(0.0, time.time() - float(started_at)))
            return snap

    def mark_warming_ready_if_idle_deploy(self) -> None:
        """Promote attached warming state to ready once telemetry confirms engine is loaded."""
        with self._lock:
            deploy_busy = self._deploy_thread is not None and self._deploy_thread.is_alive()
            phase = str(self._deployment.get("phase") or "")
        if not deploy_busy and phase == "warming":
            self._set_deployment(
                phase="ready",
                step_index=6,
                step_label="部署完成，引擎在线",
                percent=100.0,
                sub_percent=100.0,
                detail="云端引擎已就绪在线",
                eta_text="已完成",
            )

    def _set_deployment(
        self,
        *,
        phase: str,
        step_index: int,
        step_label: str,
        percent: float | None = None,
        sub_percent: float | None = None,
        detail: str | None = None,
        eta_text: str | None = None,
        error: str = "",
        reset_timer: bool = False,
    ) -> None:
        with self._lock:
            prev = self._deployment
            now = time.time()
            if phase == "idle":
                # 回到待机态时清零计时与进度，避免旧部署进度或计时残留到下一轮展示
                started_at = None
                elapsed_sec = 0
                next_pct = 0.0
                next_sub_pct = None
            else:
                if reset_timer:
                    started_at: float | None = now
                    elapsed_sec = 0
                    prev_pct = 0.0
                else:
                    started_at = prev.get("started_at")
                    if started_at is None:
                        started_at = now
                    elapsed_sec = int(max(0.0, now - float(started_at))) if started_at is not None else int(prev.get("elapsed_sec") or 0)
                    prev_pct = float(prev.get("percent") or 0.0)

                if percent is None:
                    next_pct = prev_pct
                elif phase == "error":
                    next_pct = round(float(percent), 1)
                else:
                    next_pct = max(prev_pct, min(100.0, round(float(percent), 1)))
                next_sub_pct = None if sub_percent is None else max(0.0, min(100.0, round(float(sub_percent), 1)))

            self._deployment = {
                "phase": phase,
                "step_index": step_index,
                "step_total": 6,
                "step_label": step_label,
                "percent": next_pct,
                "sub_percent": next_sub_pct,
                "detail": prev.get("detail", "") if detail is None else detail,
                "eta_text": prev.get("eta_text", "") if eta_text is None else eta_text,
                "started_at": started_at,
                "elapsed_sec": elapsed_sec,
                "error": error,
            }

    def refresh_auth_status(self, *, log_event: bool = False) -> dict[str, Any]:
        """Query Google Colab OAuth state, CU balance, hourly burn rate, and active sessions."""
        data = self._run_bridge("auth_status", timeout=25.0)
        if data is None and self.colab_bin:
            data = self._fallback_cli_auth_status()
        if data is None:
            data = {
                "ok": False,
                "logged_in": False,
                "email": "",
                "paid_balance": None,
                "burn_rate_hourly": None,
                "active_assignments": 0,
                "sessions": [],
                "error": "未检测到 colab CLI 或 colab_cli 运行环境",
            }

        clear_maya_upstream = False
        with self._lock:
            for k in ("logged_in", "email", "paid_balance", "burn_rate_hourly", "active_assignments", "sessions"):
                if k in data:
                    self._colab_state[k] = data[k]
            self._colab_state["keepalive_running"] = self.is_keepalive_running(self.config.selected_session)
            # If user has an active session matching selected_session, keep selected_gpu aligned if unset
            sessions = data.get("sessions") or []
            if isinstance(sessions, list):
                for s in sessions:
                    if isinstance(s, dict) and s.get("name") == self.config.selected_session and s.get("accelerator"):
                        acc = str(s["accelerator"]).upper()
                        if acc in ("G4", "A100", "H100", "L4", "T4"):
                            self._colab_state["selected_gpu"] = acc
                            break

            # 会话自然到期或被外部回收后（active_assignments == 0），在非部署期自动清理残留 GPU/挂载与 Maya 状态
            if bool(data.get("ok")) and bool(data.get("logged_in")) and int(data.get("active_assignments") or 0) == 0:
                deploy_busy = self._deploy_thread is not None and self._deploy_thread.is_alive()
                if not deploy_busy:
                    self._colab_state["gpu_name"] = ""
                    self._colab_state["mounts"] = {}
                    if self.config.engine_kind == "maya":
                        if str(self._deployment.get("phase") or "") in ("ready", "warming"):
                            self._set_deployment(
                                phase="idle",
                                step_index=0,
                                step_label="",
                                percent=0.0,
                                sub_percent=None,
                                detail="",
                                eta_text="",
                                error="",
                            )
                        if self.config.upstream_url:
                            clear_maya_upstream = True

        if clear_maya_upstream:
            self.config.set_selection(upstream_url="")
            self.proxy.set_upstream("", engine_kind="maya", api_key="")
            if self.on_telemetry_refresh is not None:
                self.on_telemetry_refresh()

        if log_event:
            if data.get("logged_in"):
                bal = data.get("paid_balance")
                rate = data.get("burn_rate_hourly")
                self.logs.emit(
                    "colab",
                    "info",
                    f"Colab 状态已刷新: active={data.get('active_assignments', 0)}, balance={bal} CU, rate={rate} CU/h",
                )
            else:
                self.logs.emit("colab", "warn", "Colab 尚未登录或凭据已过期")
        return self.get_colab_snapshot()

    def _fallback_cli_auth_status(self) -> dict[str, Any]:
        if not self.colab_bin:
            return {"ok": False, "logged_in": False, "sessions": []}
        rc_u, out_u, _ = self._run_bounded([self.colab_bin, "usage"], timeout=15.0)
        rc_s, out_s, _ = self._run_bounded([self.colab_bin, "sessions"], timeout=15.0)
        logged_in = rc_u == 0 or rc_s == 0
        paid_balance = None
        burn_rate = None
        m_bal = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*(?:CU|compute units?)", out_u, re.IGNORECASE)
        if m_bal:
            paid_balance = round(float(m_bal.group(1)), 2)
        m_rate = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*(?:CU/h|per hour|/hr)", out_u, re.IGNORECASE)
        if m_rate:
            burn_rate = round(float(m_rate.group(1)), 2)

        sessions: list[dict[str, Any]] = []
        for line in out_s.splitlines():
            m = re.match(
                r"^\[([^\]]+)\]\s+(\S+)\s+\|\s+Hardware:\s+(\S+)\s+\|\s+Shape:\s+(\S+)\s+\|\s+Variant:\s+(\S+)",
                line.strip(),
            )
            if m:
                sessions.append(
                    {
                        "name": m.group(1),
                        "endpoint": m.group(2),
                        "accelerator": m.group(3),
                        "shape": m.group(4),
                        "variant": m.group(5),
                    }
                )
        return {
            "ok": logged_in,
            "logged_in": logged_in,
            "email": "",
            "paid_balance": paid_balance,
            "burn_rate_hourly": burn_rate,
            "active_assignments": len(sessions),
            "sessions": sessions,
        }

    def auth_url(self) -> dict[str, Any]:
        res = self._run_bridge("auth_url", timeout=20.0)
        if res is None:
            return {"ok": False, "error": "未找到可用的 colab_cli Python 环境，请先安装 google-colab-cli"}
        if res.get("ok"):
            self.logs.emit("colab", "info", "已生成 Google OAuth2 PKCE 授权链接")
        else:
            self.logs.emit("colab", "error", f"生成 OAuth 链接失败: {res.get('error', 'unknown')}")
        return res

    def auth_code(self, code_or_url: str) -> dict[str, Any]:
        raw = (code_or_url or "").strip()
        if not raw:
            return {"ok": False, "logged_in": False, "error": "授权码不能为空"}
        if raw.startswith("http://") or raw.startswith("https://"):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(raw).query)
            if qs.get("code"):
                raw = qs["code"][0]
        res = self._run_bridge("auth_code", raw, timeout=25.0)
        if res is None:
            return {"ok": False, "logged_in": False, "error": "未找到可用的 colab_cli Python 环境"}
        if res.get("ok") and res.get("logged_in"):
            with self._lock:
                for k in ("logged_in", "email", "paid_balance", "burn_rate_hourly", "active_assignments", "sessions"):
                    if k in res:
                        self._colab_state[k] = res[k]
            self.logs.emit("colab", "success", "Google Colab OAuth 授权登录成功")
        else:
            self.logs.emit("colab", "error", f"OAuth 授权码交换失败: {res.get('error', 'unknown')}")
        return res

    def auth_logout(self) -> dict[str, Any]:
        res = self._run_bridge("auth_logout", timeout=15.0)
        if res is None:
            res = {"ok": True, "logged_in": False, "email": ""}
        with self._lock:
            self._colab_state.update(
                {
                    "logged_in": False,
                    "email": "",
                    "paid_balance": None,
                    "burn_rate_hourly": None,
                    "active_assignments": 0,
                    "sessions": [],
                    "gpu_name": "",
                    "mounts": {},
                }
            )
        self.logs.emit("colab", "info", "已退出当前 Google Colab OAuth 会话")
        return res

    def attach(self, session: str = "", engine_kind: str = "") -> dict[str, Any]:
        """Non-destructive read-only attach to an existing Colab session via a single `colab exec`."""
        sess = (session or self.config.selected_session or "easycolab").strip()
        if not self.colab_bin:
            return {"ok": False, "attached": False, "error": "未找到 colab CLI 可执行文件"}

        chosen_kind = engine_kind if engine_kind in ("maya", "strata") else self.config.engine_kind
        self.config.set_selection(session=sess, engine_kind=chosen_kind)
        self.logs.emit("colab", "info", f"正在只读探测 Colab 会话 '{sess}' (不中断远端推理与外部保活)...")

        env = self._build_subprocess_env()
        try:
            proc = subprocess.run(
                [self.colab_bin, "exec", "-s", sess, "--timeout", "45"],
                input=_REMOTE_ATTACH_PROBE_PY,
                capture_output=True,
                text=True,
                timeout=55,
                env=env,
            )
        except subprocess.TimeoutExpired:
            self.logs.emit("colab", "error", f"只读探测 '{sess}' 超时 (55s)")
            return {"ok": False, "attached": False, "error": f"colab exec 探测 '{sess}' 超时"}
        except Exception as exc:
            self.logs.emit("colab", "error", f"只读探测 '{sess}' 异常: {exc}")
            return {"ok": False, "attached": False, "error": str(exc)}

        probe = _extract_marked_json(proc.stdout, PROBE_MARKER)
        if probe is None:
            err_msg = (proc.stderr or proc.stdout or "").strip()[-400:] or f"returncode={proc.returncode}"
            self.logs.emit("colab", "error", f"探测 '{sess}' 未返回有效 JSON: {err_msg}")
            return {"ok": False, "attached": False, "error": f"远端探测失败: {err_msg}"}

        gpu_name = str(probe.get("gpu_name") or "")
        processes = probe.get("processes") if isinstance(probe.get("processes"), dict) else {}
        mounts = probe.get("mounts") if isinstance(probe.get("mounts"), dict) else {}
        tunnel_url = str(probe.get("tunnel_url") or "").strip().rstrip("/")
        keepalive_running = self.is_keepalive_running(sess)

        inferred_gpu = None
        g_up = gpu_name.upper()
        for key, label in (("RTX PRO 6000", "G4"), ("BLACKWELL", "G4"), ("A100", "A100"), ("H100", "H100"), ("L4", "L4"), ("T4", "T4")):
            if key in g_up:
                inferred_gpu = label
                break

        detected_kind = chosen_kind
        if not engine_kind:
            if processes.get("strata_alive") and not processes.get("maya_alive"):
                detected_kind = "strata"
            elif processes.get("maya_alive"):
                detected_kind = "maya"

        with self._lock:
            self._colab_state["gpu_name"] = gpu_name
            self._colab_state["mounts"] = mounts
            self._colab_state["keepalive_running"] = keepalive_running
            self._colab_state["selected_session"] = sess
            if inferred_gpu:
                self._colab_state["selected_gpu"] = inferred_gpu

        self.refresh_auth_status(log_event=False)

        if tunnel_url:
            api_key = self.config.read_credential_file(
                "strata_api_key" if detected_kind == "strata" else "maya_api_key"
            )
            self.config.set_selection(
                gpu=inferred_gpu,
                session=sess,
                engine_kind=detected_kind,
                upstream_url=tunnel_url,
            )
            self.proxy.set_upstream(tunnel_url, engine_kind=detected_kind, api_key=api_key)
            tel = self.on_telemetry_refresh() if self.on_telemetry_refresh is not None else {}
            with self._lock:
                deploy_busy = self._deploy_thread is not None and self._deploy_thread.is_alive()
            if not deploy_busy:
                local_health = probe.get("local_health") if isinstance(probe.get("local_health"), dict) else {}
                maya_tail = probe.get("maya_log_tail") if isinstance(probe.get("maya_log_tail"), list) else []
                tel_ready = isinstance(tel, dict) and bool(tel.get("online")) and (
                    detected_kind == "strata" or bool(tel.get("loaded"))
                )
                if _is_health_ready(local_health) or tel_ready:
                    self._set_deployment(
                        phase="ready",
                        step_index=6,
                        step_label="部署完成，引擎在线",
                        percent=100.0,
                        sub_percent=100.0,
                        detail="云端引擎已就绪在线",
                        eta_text="已完成",
                    )
                elif processes.get("maya_alive") and maya_tail:
                    parsed_warm = _parse_maya_warmup_lines([str(x) for x in maya_tail], {})
                    if parsed_warm:
                        self._set_deployment(
                            phase="warming",
                            step_index=6,
                            step_label=parsed_warm["label"],
                            percent=parsed_warm["percent"],
                            sub_percent=parsed_warm["sub_percent"],
                            detail=parsed_warm["detail"],
                            eta_text=parsed_warm["eta_text"],
                        )
                    else:
                        self._set_deployment(
                            phase="warming",
                            step_index=6,
                            step_label="隧道已连通 · 正在等待权重装载...",
                            percent=56.0,
                            detail="远端引擎已启动，等待开放 :8000",
                            eta_text="权重装载阶段预计 ~14–18 分钟",
                        )
            self.logs.emit(
                "colab",
                "success",
                f"无损纳管 '{sess}' 成功: GPU={gpu_name or 'unknown'}, 隧道已绑定本地代理 :{self.proxy.proxy_port}, keepalive={keepalive_running}",
            )
        else:
            if inferred_gpu:
                self.config.set_selection(gpu=inferred_gpu, session=sess, engine_kind=detected_kind)
            self.logs.emit(
                "colab",
                "warn",
                f"已探测 '{sess}' (GPU={gpu_name or 'unknown'}), 但未在 cloudflared 日志中发现隧道 URL",
            )

        return {
            "ok": True,
            "attached": True,
            "session": sess,
            "engine_kind": detected_kind,
            "gpu_name": gpu_name,
            "processes": processes,
            "mounts": mounts,
            "tunnel_url": tunnel_url,
            "tunnel_masked": mask_url(tunnel_url) if tunnel_url else "",
            "keepalive_running": keepalive_running,
            "local_health": probe.get("local_health"),
            "colab": self.get_colab_snapshot(),
        }

    def keepalive(self, *, enabled: bool, session: str = "", interval_sec: int = 720) -> dict[str, Any]:
        """Manage 12-minute Jupyter kernel keepalive without disturbing external daemons."""
        sess = (session or self.config.selected_session or "easycolab").strip()
        interval = max(60, min(3600, int(interval_sec or 720)))
        ext_pids, stu_pids = self._find_keepalive_pids(sess)

        if enabled:
            if ext_pids:
                self.logs.emit(
                    "keepalive",
                    "info",
                    f"检测到外部 keepalive_colab.sh 已在运行 (PID {', '.join(map(str, ext_pids))})，直接复用，不重复启动",
                )
                return {
                    "ok": True,
                    "keepalive_running": True,
                    "external": True,
                    "pids": ext_pids,
                    "session": sess,
                }
            if stu_pids:
                return {
                    "ok": True,
                    "keepalive_running": True,
                    "external": False,
                    "pids": stu_pids,
                    "session": sess,
                }

            script_path = REPO_ROOT / "scripts" / "keepalive_colab.sh"
            if script_path.is_file():
                log_path = Path(tempfile.gettempdir()) / f"colab-keepalive-studio-{sess}.log"
                log_fh = open(log_path, "a", encoding="utf-8")
                self._keepalive_session = sess
                self._keepalive_proc = subprocess.Popen(
                    ["bash", str(script_path), sess, str(interval)],
                    stdout=log_fh,
                    stderr=subprocess.STDOUT,
                    text=True,
                    env=self._build_subprocess_env(),
                    start_new_session=True,
                )
                log_fh.close()
                self.logs.emit(
                    "keepalive",
                    "success",
                    f"已启动 Studio 托管保活守护 (session={sess}, interval={interval}s, PID={self._keepalive_proc.pid})",
                )
                return {
                    "ok": True,
                    "keepalive_running": True,
                    "external": False,
                    "pids": [self._keepalive_proc.pid],
                    "session": sess,
                }

            # Fallback internal Python keepalive loop when bundled without shell script
            self._keepalive_stop_ev.clear()
            self._keepalive_session = sess

            def _loop() -> None:
                while not self._keepalive_stop_ev.wait(interval):
                    if self.colab_bin:
                        self._run_bounded(
                            [self.colab_bin, "exec", "-s", sess, "--timeout", "30"],
                            stdin_data="_studio_hb = 1\n",
                            timeout=40.0,
                        )
                        self.logs.emit("keepalive", "info", f"Studio 内置心跳已发送至 '{sess}'")

            self._keepalive_thread = threading.Thread(target=_loop, name="studio-keepalive", daemon=True)
            self._keepalive_thread.start()
            self.logs.emit("keepalive", "success", f"已启动内置 Python 保活线程 (session={sess}, interval={interval}s)")
            return {
                "ok": True,
                "keepalive_running": True,
                "external": False,
                "pids": [os.getpid()],
                "session": sess,
            }

        # Disable requested: only terminate Studio-owned keepalive; never kill external keepalive_colab.sh
        stopped_studio = False
        if self._keepalive_proc is not None and self._keepalive_proc.poll() is None:
            try:
                os.killpg(self._keepalive_proc.pid, signal.SIGTERM)
                self._keepalive_proc.wait(timeout=4)
            except Exception:
                try:
                    self._keepalive_proc.kill()
                except Exception:
                    pass
            self._keepalive_proc = None
            stopped_studio = True
        if self._keepalive_thread is not None and self._keepalive_thread.is_alive():
            self._keepalive_stop_ev.set()
            stopped_studio = True

        ext_after, _ = self._find_keepalive_pids(sess)
        if ext_after:
            self.logs.emit(
                "keepalive",
                "warn",
                f"外部 keepalive_colab.sh (PID {', '.join(map(str, ext_after))}) 仍在运行；安全策略禁止 Studio 强杀外部进程",
            )
            return {
                "ok": True,
                "keepalive_running": True,
                "external": True,
                "pids": ext_after,
                "stopped_studio": stopped_studio,
                "message": "外部 keepalive_colab.sh 仍在运行（安全策略：仅停止由 Studio 启动的保活进程）",
            }
        if stopped_studio:
            self.logs.emit("keepalive", "info", f"已停止 Studio 托管保活守护 (session={sess})")
        return {"ok": True, "keepalive_running": False, "external": False, "pids": [], "stopped_studio": stopped_studio}

    def deploy(
        self,
        *,
        gpu: str = "G4",
        session: str = "easycolab",
        engine_kind: str = "maya",
        mode: str = "b1_hf_fuse",
        settings: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Start asynchronous 6-stage Colab provisioning & Maya/Strata deployment."""
        gpu_clean = (gpu or "G4").strip().upper()
        if gpu_clean.lower() not in SUPPORTED_GPUS:
            return {"ok": False, "error": f"不支持的 GPU 型号: {gpu}"}

        sess = (session or "easycolab").strip()
        kind = engine_kind if engine_kind in ("maya", "strata") else "maya"
        mode_id = mode if mode in MODES_BY_ID else "b1_hf_fuse"

        with self._lock:
            if self._deploy_thread is not None and self._deploy_thread.is_alive():
                return {"ok": False, "error": "已有部署任务正在运行中，请等待完成", "deployment": self.get_deployment_snapshot()}

        if settings:
            self.config.update_settings(settings)
        self.config.set_selection(gpu=gpu_clean, session=sess, engine_kind=kind, maya_mode=mode_id)

        self._set_deployment(
            phase="provisioning",
            step_index=1,
            step_label="分配与校验 Colab GPU 实例",
            percent=2.0,
            sub_percent=None,
            detail=f"请求 {gpu_clean} 实例规格",
            eta_text="本步预计 ~10–30 秒 · 首次冷启全程约 22–28 分钟",
            reset_timer=True,
        )
        self._deploy_thread = threading.Thread(
            target=self._deploy_worker,
            args=(gpu_clean, sess, kind, mode_id),
            name="studio-colab-deploy",
            daemon=True,
        )
        self._deploy_thread.start()
        return {"ok": True, "started": True, "deployment": self.get_deployment_snapshot()}

    def _upload_file(self, session: str, local_path: Path, remote_path: str) -> None:
        if not self.colab_bin:
            raise RuntimeError("未找到 colab CLI")
        rc, out, err = self._run_bounded(
            [self.colab_bin, "upload", "-s", session, str(local_path), remote_path],
            timeout=180.0,
        )
        if rc != 0:
            raise RuntimeError(f"上传 {local_path.name} 失败: {(err or out).strip()[-300:]}")

    def _deploy_worker(self, gpu: str, session: str, engine_kind: str, mode_id: str) -> None:
        try:
            self.logs.emit("deploy", "info", f"[1/6] 开始部署 {engine_kind} ({mode_id}) 至 Colab '{session}' ({gpu})...")
            if not self.colab_bin:
                raise RuntimeError("未检测到 colab CLI 可执行文件")
            if gpu.lower() in SINGLE_SHAPE_GPUS:
                self.logs.emit("deploy", "info", f"G4/单规格防呆已激活: {gpu} 不传 high_mem / Shape.HIGH_RAM")

            # Step 1: Allocate / reuse session safely
            if self.colab_python:
                ens = self._run_bridge("ensure_session", session, gpu, timeout=90.0)
                if not ens or not ens.get("ok"):
                    raise RuntimeError((ens or {}).get("error") or "Colab 实例分配失败")
            elif self.colab_bin:
                cmd = [self.colab_bin, "new", "-s", session, "--gpu", gpu]
                if gpu.lower() in HIGH_MEM_GPUS:
                    cmd.append("--high-mem")
                rc, out, err = self._run_bounded(cmd, timeout=90.0)
                if rc != 0:
                    raise RuntimeError((err or out).strip()[-300:] or "colab new 失败")
            else:
                raise RuntimeError("未检测到 colab CLI 或 colab_cli 运行环境")

            # Step 2: Upload runtime packages & credentials from ~/.config/maya-gcs/
            self._set_deployment(
                phase="uploading",
                step_index=2,
                step_label="上传预编译运行包与安全凭据",
                percent=6.0,
                sub_percent=0.0,
                detail="准备上传运行包与加速源码...",
                eta_text="本步预计 ~15–30 秒",
            )
            self.logs.emit("deploy", "info", "[2/6] 正在上传运行包与脚本至 /tmp...")

            res_dir = REPO_ROOT / "resources"
            scripts_dir = REPO_ROOT / "scripts"
            src_dir = REPO_ROOT / "src"

            uploads: list[tuple[Path, str]] = [
                (res_dir / "maya-g4-runtime.tar.gz", "/tmp/maya-g4-runtime.tar.gz"),
                (res_dir / "maya-ds4.json", "/tmp/maya-ds4.json"),
                (res_dir / "pack-meta-256g.tar.gz", "/tmp/pack-meta-256g.tar.gz"),
                (scripts_dir / "start_g4_256g.sh", "/tmp/start_g4_256g.sh"),
            ]
            if gpu != "G4" and (res_dir / "maya-a100-sm80-build.tar.gz").is_file():
                uploads.append((res_dir / "maya-a100-sm80-build.tar.gz", "/tmp/maya-a100-sm80-build.tar.gz"))
            for cname in ("hf_ro_fuse.c", "gcs_tls_pread.c"):
                cp = src_dir / cname
                if cp.is_file():
                    uploads.append((cp, f"/tmp/{cname}"))

            total_uploads = len(uploads)
            for idx, (local_p, remote_p) in enumerate(uploads, start=1):
                if not local_p.is_file():
                    raise RuntimeError(f"缺少部署资源文件: {local_p.name}")
                self._set_deployment(
                    phase="uploading",
                    step_index=2,
                    step_label="上传预编译运行包与安全凭据",
                    percent=round(6.0 + 6.0 * (idx / max(1, total_uploads)), 1),
                    sub_percent=round(100.0 * idx / max(1, total_uploads), 1),
                    detail=f"上传组件 ({idx}/{total_uploads}): {local_p.name}",
                    eta_text="本步预计 ~15–30 秒",
                )
                self._upload_file(session, local_p, remote_p)

            # Upload credentials from ~/.config/maya-gcs/ (respecting pure-hf / shm mode isolation)
            hf_tok = CONFIG_DIR / "hf-token"
            if hf_tok.is_file():
                self._upload_file(session, hf_tok, "/tmp/hf-token")

            if mode_id not in ("b1_pure_hf", "b2_shm"):
                gcs_key = CONFIG_DIR / "gcs-key.json"
                gcs_bucket = CONFIG_DIR / "bucket"
                if gcs_key.is_file():
                    self._upload_file(session, gcs_key, "/tmp/gcs-key.json")
                if gcs_bucket.is_file():
                    self._upload_file(session, gcs_bucket, "/tmp/gcs-bucket")

            maya_api_key = CONFIG_DIR / "maya-api-key"
            has_maya_api_key = maya_api_key.is_file() and bool(self.config.read_credential_file("maya_api_key"))
            if has_maya_api_key:
                self._upload_file(session, maya_api_key, "/tmp/maya-api-key")

            # Step 3 & 4: Detached remote execution with live log & shard-download telemetry streaming
            self._set_deployment(
                phase="mounting",
                step_index=3,
                step_label="准备运行环境与挂载 /mnt/hf FUSE3",
                percent=14.0,
                sub_percent=None,
                detail="启动远端部署守护并初始化环境...",
                eta_text="环境挂载预计 ~1–2 分钟 · 全程约 22–28 分钟",
            )
            cfg_settings = self.config.get_settings()
            script_env = resolve_mode_env(mode_id, cfg_settings, for_script=True)
            env_exports = " ".join(f"{k}={shlex_quote(v)}" for k, v in script_env.items())

            self.logs.emit("deploy", "info", f"[3/6] 正在远端执行 start_g4_256g.sh ({env_exports})...")

            clean_stale_gcs = (
                "rm -f /tmp/gcs-key.json /tmp/gcs-bucket\n" if mode_id in ("b1_pure_hf", "b2_shm") else ""
            )
            clean_stale_api = "" if has_maya_api_key else "rm -f /tmp/maya-api-key\n"
            self._run_remote_boot_streaming(
                session=session,
                mode_id=mode_id,
                env_exports=env_exports,
                clean_stale_gcs=clean_stale_gcs,
                clean_stale_api=clean_stale_api,
            )

            if engine_kind == "strata":
                self._launch_strata_on_colab(session, cfg_settings)

            # Step 5: Tunnel extraction & keepalive
            self._set_deployment(
                phase="tunneling",
                step_index=5,
                step_label="建立 Cloudflare 隧道与启动保活",
                percent=54.0,
                sub_percent=None,
                detail="提取 *.trycloudflare.com 并启动 12m 保活",
                eta_text="预计 ~5–10 秒",
            )
            self.logs.emit("deploy", "info", "[5/6] 正在等待并提取隧道 URL...")
            tunnel_url = ""
            for _ in range(18):
                att = self.attach(session=session, engine_kind=engine_kind)
                tunnel_url = str(att.get("tunnel_url") or "")
                if tunnel_url:
                    break
                time.sleep(3.0)

            if not tunnel_url:
                raise RuntimeError("未检测到 Cloudflare 隧道 URL，请检查远端 cloudflared.log")

            # Step 6: Bind proxy, start keepalive & wait for full weight load into VRAM/RAM
            self._set_deployment(
                phase="warming",
                step_index=6,
                step_label="隧道已连通，正在将权重装入显存与内存...",
                percent=56.0,
                sub_percent=0.0,
                detail="正在初始化 GGUF 索引并流式装载 748B 专家...",
                eta_text="权重装载阶段预计 ~14–18 分钟",
            )
            self.keepalive(enabled=True, session=session, interval_sec=720)
            self._wait_for_engine_ready(session=session, tunnel_url=tunnel_url, engine_kind=engine_kind)
            if self.on_telemetry_refresh is not None:
                self.on_telemetry_refresh()
            self._set_deployment(
                phase="ready",
                step_index=6,
                step_label="部署完成，引擎在线",
                percent=100.0,
                sub_percent=100.0,
                detail="96GB VRAM + 系统内存专家池已全部就绪",
                eta_text="已完成",
            )
            self.logs.emit("deploy", "success", "[6/6] 引擎权重加载完毕，WebUI 与 /v1 推理接口已正式上线！")
        except Exception as exc:
            self._set_deployment(
                phase="error",
                step_index=0,
                step_label="部署失败",
                detail=str(exc),
                eta_text="已中止",
                error=str(exc),
            )
            self.logs.emit("deploy", "error", f"部署异常: {exc}")

    def _run_remote_boot_streaming(
        self,
        *,
        session: str,
        mode_id: str,
        env_exports: str,
        clean_stale_gcs: str,
        clean_stale_api: str,
    ) -> None:
        """Run start_g4_256g.sh detached and stream log chunks + NVMe shard progress every ~4s."""
        runner_script = (
            "#!/usr/bin/env bash\n"
            "set -uo pipefail\n"
            f"{clean_stale_gcs}"
            f"{clean_stale_api}"
            "mkdir -p /content/project-maya\n"
            "tar -xzf /tmp/maya-g4-runtime.tar.gz -C /content/project-maya/\n"
            "cp -f /tmp/maya-ds4.json /content/project-maya/maya-ds4.json\n"
            "cp -f /tmp/pack-meta-256g.tar.gz /content/project-maya/pack-meta-256g.tar.gz\n"
            "chmod +x /tmp/start_g4_256g.sh\n"
            f"env {env_exports} bash /tmp/start_g4_256g.sh\n"
            "rc=$?\n"
            'echo "$rc" > /tmp/studio_boot.rc\n'
            'exit "$rc"\n'
        )
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".sh", delete=False) as tf:
            tf.write(runner_script)
            tmp_runner = Path(tf.name)
        try:
            self._upload_file(session, tmp_runner, "/tmp/studio_boot_runner.sh")
        finally:
            try:
                tmp_runner.unlink()
            except OSError:
                pass

        launch_py = (
            "import subprocess\n"
            "cmd = \"rm -f /tmp/studio_boot.log /tmp/studio_boot.rc /tmp/studio_boot.pid "
            "&& chmod +x /tmp/studio_boot_runner.sh "
            "&& (if command -v stdbuf >/dev/null 2>&1; then "
            "nohup stdbuf -oL -eL bash /tmp/studio_boot_runner.sh > /tmp/studio_boot.log 2>&1 < /dev/null & "
            "else nohup bash /tmp/studio_boot_runner.sh > /tmp/studio_boot.log 2>&1 < /dev/null & fi; "
            "echo $! > /tmp/studio_boot.pid)\"\n"
            "subprocess.run(['bash', '-lc', cmd], check=True)\n"
        )
        rc, out, err = self._run_bounded(
            [self.colab_bin, "exec", "-s", session, "--timeout", "30"],
            stdin_data=launch_py,
            timeout=40.0,
        )
        if rc != 0:
            raise RuntimeError((err or out).strip()[-300:] or "启动远端引导脚本失败")

        if mode_id == "a_dual_disk":
            target_bytes = 346_378_296_480
        elif mode_id in ("b1_gcs", "b2_shm"):
            target_bytes = 110_595_290_592
        else:
            target_bytes = 205_809_923_712

        offset = 0
        prev_bytes = 0
        prev_t = time.monotonic()
        ema_bps = 0.0
        last_dl_log_t = 0.0
        in_download_stage = False
        in_compile_stage = False
        deadline = time.monotonic() + 1800.0
        poll_fail_streak = 0

        while time.monotonic() < deadline:
            poll_py = (
                "import json, os\n"
                f"offset = {offset}\n"
                "chunk = ''\n"
                "new_off = offset\n"
                "if os.path.isfile('/tmp/studio_boot.log'):\n"
                "    try:\n"
                "        with open('/tmp/studio_boot.log', 'rb') as f:\n"
                "            f.seek(offset)\n"
                "            data = f.read(65536)\n"
                "            new_off = offset + len(data)\n"
                "            chunk = data.decode('utf-8', 'replace')\n"
                "    except Exception:\n"
                "        pass\n"
                "rc = None\n"
                "if os.path.isfile('/tmp/studio_boot.rc'):\n"
                "    try:\n"
                "        rc = int(open('/tmp/studio_boot.rc').read().strip())\n"
                "    except Exception:\n"
                "        pass\n"
                "alive = False\n"
                "if os.path.isfile('/tmp/studio_boot.pid'):\n"
                "    try:\n"
                "        pid = int(open('/tmp/studio_boot.pid').read().strip())\n"
                "        os.kill(pid, 0)\n"
                "        alive = True\n"
                "    except Exception:\n"
                "        pass\n"
                "sb = 0\n"
                "for d in ('/content/maya-models', '/mnt/local-scratch/maya-shards', '/dev/shm/maya-s2'):\n"
                "    if os.path.isdir(d):\n"
                "        for dp, _, fns in os.walk(d):\n"
                "            for fn in fns:\n"
                "                if fn.endswith('.gguf') or fn.endswith('.incomplete'):\n"
                "                    fp = os.path.join(dp, fn)\n"
                "                    if not os.path.islink(fp):\n"
                "                        try:\n"
                "                            sb += os.path.getsize(fp)\n"
                "                        except OSError:\n"
                "                            pass\n"
                "print('STUDIO_BOOT_POLL:' + json.dumps({'offset': new_off, 'chunk': chunk, 'rc': rc, 'alive': alive, 'shard_bytes': sb}, ensure_ascii=False))\n"
            )
            p_rc, p_out, _ = self._run_bounded(
                [self.colab_bin, "exec", "-s", session, "--timeout", "20"],
                stdin_data=poll_py,
                timeout=25.0,
            )
            parsed = _extract_marked_json(p_out, "STUDIO_BOOT_POLL:")
            if parsed is None:
                poll_fail_streak += 1
                if poll_fail_streak >= 10:
                    raise RuntimeError("连续多次无法轮询远端部署状态，请检查 Colab 会话连接")
                time.sleep(4.0)
                continue
            poll_fail_streak = 0

            offset = int(parsed.get("offset") or offset)
            chunk = str(parsed.get("chunk") or "")
            boot_rc = parsed.get("rc")
            alive = bool(parsed.get("alive"))
            shard_bytes = int(parsed.get("shard_bytes") or 0)

            for raw_ln in chunk.splitlines():
                ln = raw_ln.replace("\r", "").strip()
                if not ln:
                    continue
                self.logs.emit("deploy", "info", ln)
                if "[4/6]" in ln:
                    in_download_stage = True
                if "[5/6]" in ln or "[6/6]" in ln or "gcs_tls_pread" in ln:
                    in_compile_stage = True
                    in_download_stage = False

            now = time.monotonic()
            dt = max(0.1, now - prev_t)
            if shard_bytes > prev_bytes and dt > 0.5:
                inst_bps = (shard_bytes - prev_bytes) / dt
                ema_bps = inst_bps if ema_bps <= 0.0 else (0.35 * inst_bps + 0.65 * ema_bps)
            prev_bytes = max(prev_bytes, shard_bytes)
            prev_t = now

            if in_compile_stage:
                self._set_deployment(
                    phase="starting",
                    step_index=4,
                    step_label="编译 gcs_tls_pread.so 加速库并拉起引擎",
                    percent=51.0,
                    sub_percent=None,
                    detail="gcc -O2 编译双模态预读库并后台启动 maya.py",
                    eta_text="本步预计 ~15–30 秒",
                )
            elif in_download_stage or shard_bytes > 50_000_000:
                frac = min(1.0, shard_bytes / max(1, target_bytes))
                pct = round(18.0 + 30.0 * frac, 1)
                sub_pct = round(100.0 * frac, 1)
                cur_gib = shard_bytes / (1024 ** 3)
                tot_gib = target_bytes / (1024 ** 3)
                speed_str = f" · {ema_bps / 1048576:.0f} MiB/s" if ema_bps > 1_048_576 else ""
                if ema_bps > 5_000_000 and shard_bytes < target_bytes:
                    dl_rem = max(0.0, (target_bytes - shard_bytes) / ema_bps)
                    eta = f"分片剩余 ~{_fmt_duration(dl_rem)} · 预计总剩余 ~{_fmt_duration(dl_rem + 920.0)}"
                elif frac >= 0.99:
                    eta = "分片已就绪，即将编译加速库 (~15s)"
                else:
                    eta = "分片拉取预计 ~8–11 分钟 · 随后装入显存 ~15 分钟"
                self._set_deployment(
                    phase="mounting",
                    step_index=3,
                    step_label=f"高速拉取 NVMe 模型分片 ({sub_pct:.1f}%)",
                    percent=pct,
                    sub_percent=sub_pct,
                    detail=f"已拉取 {cur_gib:.1f} / {tot_gib:.1f} GiB{speed_str}",
                    eta_text=eta,
                )
                if now - last_dl_log_t >= 16.0:
                    last_dl_log_t = now
                    self.logs.emit(
                        "deploy",
                        "info",
                        f"[3/6] NVMe 分片进度: {sub_pct:.1f}% ({cur_gib:.1f} / {tot_gib:.1f} GiB{speed_str})",
                    )

            if boot_rc is not None:
                if int(boot_rc) != 0:
                    raise RuntimeError(f"远端启动脚本失败 (exit={boot_rc})，请查看右侧部署日志")
                return
            if not alive and offset > 0 and p_rc == 0:
                # Re-check rc briefly before exiting
                if boot_rc is None:
                    raise RuntimeError("远端部署进程意外退出，未写入退出码，请检查右侧日志")

            time.sleep(4.0)

        raise RuntimeError("远端启动脚本执行超时 (30m)")

    def _wait_for_engine_ready(self, *, session: str, tunnel_url: str, engine_kind: str) -> None:
        """Wait until the remote engine finishes loading experts into VRAM/RAM and serves :8000."""
        self.logs.emit("deploy", "info", "[6/6] 隧道已建立，正在等待远端引擎完成权重装入并监听 :8000...")
        api_key = self.config.read_credential_file("strata_api_key" if engine_kind == "strata" else "maya_api_key")
        deadline = time.monotonic() + 2400.0
        last_log_check = 0.0
        last_label = ""
        ram_track: dict[str, float] = {}
        log_probe_py = (
            "from pathlib import Path\n"
            "p = Path('/content/project-maya/maya-ds4.log')\n"
            "if p.is_file():\n"
            "    print('\\n'.join(p.read_text(errors='replace').splitlines()[-40:]))\n"
        )

        while time.monotonic() < deadline:
            tel = fetch_engine_telemetry(tunnel_url, engine_kind=engine_kind, api_key=api_key, timeout=4.0)
            if tel.get("online") and (engine_kind == "strata" or tel.get("loaded")):
                return

            now = time.monotonic()
            if engine_kind == "maya" and self.colab_bin and (now - last_log_check >= 8.0):
                last_log_check = now
                rc, out, _ = self._run_bounded(
                    [self.colab_bin, "exec", "-s", session, "--timeout", "15"],
                    stdin_data=log_probe_py,
                    timeout=20.0,
                )
                parsed = None
                if rc == 0 and out:
                    parsed = _parse_maya_warmup_lines(out.splitlines(), ram_track)
                if parsed:
                    self._set_deployment(
                        phase="warming",
                        step_index=6,
                        step_label=parsed["label"],
                        percent=parsed["percent"],
                        sub_percent=parsed["sub_percent"],
                        detail=parsed["detail"],
                        eta_text=parsed["eta_text"],
                    )
                    log_line = f"[6/6] {parsed['label']} · {parsed['detail']} · {parsed['eta_text']}"
                    if log_line != last_label:
                        last_label = log_line
                        self.logs.emit("deploy", "info", log_line)
                elif tel.get("online"):
                    fallback_lbl = "引擎端口 :8000 已监听，正在完成最终权重初始化..."
                    self._set_deployment(
                        phase="warming",
                        step_index=6,
                        step_label=fallback_lbl,
                        percent=99.0,
                        sub_percent=99.0,
                        detail="CUDA 图与预热即将完成",
                        eta_text="预计剩余 < 15s",
                    )
                    if fallback_lbl != last_label:
                        last_label = fallback_lbl
                        self.logs.emit("deploy", "info", f"[6/6] {fallback_lbl}")

            time.sleep(5.0)

        raise RuntimeError("等待远端引擎加载权重超时 (40m)，请查看远端 maya-ds4.log")

    def _launch_strata_on_colab(self, session: str, settings: dict[str, Any]) -> None:
        """Start Strata mode via serve/server.py --engine strata when requested on Colab."""
        model_arg = str(settings.get("strata_model") or "").strip()
        max_ctx = int(settings.get("strata_max_context") or 262144)
        api_key = self.config.read_credential_file("strata_api_key")
        script = (
            "import json, os, subprocess\n"
            f"model_id = {model_arg!r}\n"
            f"max_ctx = {max_ctx!r}\n"
            f"api_key = {api_key!r}\n"
            "cmd = ['bash', '-lc', f\"nohup /content/project-maya/.venv/bin/python /content/project-maya/serve/server.py --engine strata --config /content/project-maya/maya-ds4.json --port 8000 > /content/project-maya/strata-console.log 2>&1 < /dev/null &\"]\n"
            "subprocess.run(cmd, check=False)\n"
        )
        self._run_bounded([self.colab_bin, "exec", "-s", session, "--timeout", "45"], stdin_data=script, timeout=55.0)

    def stop_session(self, *, session: str = "", confirm: bool = False) -> dict[str, Any]:
        """Release active Colab instance ONLY when confirm is explicitly True."""
        if confirm is not True:
            return {"ok": False, "error": "必须传入 confirm: true 才可释放云端 Colab 实例"}

        sess = (session or self.config.selected_session or "easycolab").strip()
        self.keepalive(enabled=False, session=sess)

        res = self._run_bridge("stop_session", sess, timeout=35.0)
        if res is None and self.colab_bin:
            rc, out, err = self._run_bounded([self.colab_bin, "stop", "-s", sess], timeout=35.0)
            res = {"ok": rc == 0, "stopped_count": 1 if rc == 0 else 0, "error": (err or out).strip()}

        if res is None:
            return {"ok": False, "error": "未找到 colab CLI 或 colab_cli"}

        if res.get("ok"):
            with self._lock:
                self._colab_state["gpu_name"] = ""
                self._colab_state["mounts"] = {}
            self._set_deployment(
                phase="idle",
                step_index=0,
                step_label="",
                percent=0.0,
                sub_percent=None,
                detail="",
                eta_text="",
                error="",
            )
            if self.config.engine_kind == "maya":
                self.config.set_selection(upstream_url="")
                self.proxy.set_upstream("", engine_kind="maya", api_key="")
                if self.on_telemetry_refresh is not None:
                    self.on_telemetry_refresh()
            self.refresh_auth_status(log_event=False)
            self.logs.emit("colab", "warn", f"已释放 Colab 会话 '{sess}'")
        else:
            self.logs.emit("colab", "error", f"释放 Colab 会话失败: {res.get('error', 'unknown')}")
        return res

    def exec_command(self, *, preset: str = "", command: str = "", session: str = "") -> dict[str, Any]:
        """Run a safe diagnostic preset or audited custom shell command on Colab or locally."""
        sess = (session or self.config.selected_session or "easycolab").strip()
        preset_key = (preset or "custom").strip().lower()
        t0 = time.perf_counter()

        if preset_key == "colab_usage":
            snap = self.refresh_auth_status(log_event=False)
            out_lines = [
                f"logged_in: {snap.get('logged_in')}",
                f"paid_balance: {snap.get('paid_balance')} CU",
                f"burn_rate_hourly: {snap.get('burn_rate_hourly')} CU/h",
                f"active_assignments: {snap.get('active_assignments')}",
                f"keepalive_running: {snap.get('keepalive_running')}",
                f"sessions: {json.dumps(snap.get('sessions', []), ensure_ascii=False)}",
            ]
            output = "\n".join(out_lines)
            self.logs.emit("cmd", "info", f"[preset:colab_usage] balance={snap.get('paid_balance')} CU")
            for line in out_lines:
                self.logs.emit("cmd", "info", line)
            return {
                "ok": True,
                "preset": preset_key,
                "exit_code": 0,
                "stdout": output,
                "stderr": "",
                "output": output,
                "duration_ms": round((time.perf_counter() - t0) * 1000.0, 1),
            }

        preset_cmds = {
            "nvidia_smi": "nvidia-smi",
            "mounts": "df -h && echo '--- MOUNTS ---' && mount | grep -E '/mnt/|/dev/shm' || true",
            "tail_engine": "tail -n 60 /content/project-maya/maya-ds4.log 2>/dev/null || tail -n 60 /content/project-maya/maya-console.log 2>/dev/null || echo 'no engine log'",
            "processes": (
                "ps -ef | grep -E 'maya\\.py|maya-ds4|serve/server\\.py|strata|cloudflared|hf_ro_fuse|gcsfuse|refresher' | grep -v grep || true; "
                "echo '--- TUNNEL LOG ---'; "
                "grep -hoE 'https://[a-zA-Z0-9-]+\\.trycloudflare\\.com' /content/project-maya/cloudflared.log /tmp/cloudflared.log 2>/dev/null | tail -n 5 || true"
            ),
        }

        if preset_key == "custom":
            shell_cmd = (command or "").strip()
            if not shell_cmd:
                return {"ok": False, "error": "custom 命令不能为空", "exit_code": 400, "stdout": "", "stderr": "", "output": ""}
            self.logs.emit("cmd", "warn", f"[custom cmd] session={sess} cmd={shell_cmd}")
        elif preset_key in preset_cmds:
            shell_cmd = preset_cmds[preset_key]
            self.logs.emit("cmd", "info", f"[preset:{preset_key}] session={sess}")
        else:
            return {"ok": False, "error": f"未知命令预设: {preset_key}", "exit_code": 400, "stdout": "", "stderr": "", "output": ""}

        if not self.colab_bin:
            return {"ok": False, "error": "未找到 colab CLI 可执行文件", "exit_code": 127, "stdout": "", "stderr": "", "output": ""}

        remote_py = (
            "import subprocess, sys\n"
            f"cmd = {shell_cmd!r}\n"
            "p = subprocess.run(['bash', '-lc', cmd], capture_output=True, text=True)\n"
            "if p.stdout:\n"
            "    sys.stdout.write(p.stdout)\n"
            "if p.stderr:\n"
            "    sys.stderr.write(p.stderr)\n"
            "sys.stdout.flush()\n"
            "sys.stderr.flush()\n"
            "if p.returncode != 0:\n"
            "    print(f'__EXIT_CODE__:{p.returncode}')\n"
        )
        rc, out, err = self._run_bounded(
            [self.colab_bin, "exec", "-s", sess, "--timeout", "45"],
            stdin_data=remote_py,
            timeout=58.0,
        )
        dur = round((time.perf_counter() - t0) * 1000.0, 1)
        m_ec = re.search(r"__EXIT_CODE__:(\d+)", out)
        cmd_rc = int(m_ec.group(1)) if m_ec else rc
        clean_out = re.sub(r"__EXIT_CODE__:\d+\n?", "", out).strip()
        combined = clean_out if not err.strip() else f"{clean_out}\n{err.strip()}".strip()

        out_lines = [ln for ln in clean_out.splitlines() if ln.strip()]
        if out_lines:
            max_emit = 60
            for ln in out_lines[:max_emit]:
                self.logs.emit("cmd", "info" if cmd_rc == 0 else "warn", ln)
            if len(out_lines) > max_emit:
                self.logs.emit("cmd", "info", f"... (已省略 {len(out_lines) - max_emit} 行输出)")
        elif not err.strip():
            self.logs.emit("cmd", "info", f"[{preset_key}] (无输出, exit={cmd_rc}, {dur}ms)")

        if err.strip():
            for ln in err.strip().splitlines()[:20]:
                if ln.strip():
                    self.logs.emit("cmd", "warn", ln)

        if preset_key == "custom":
            self.logs.emit("cmd", "info" if cmd_rc == 0 else "warn", f"[custom cmd done] exit={cmd_rc} duration={dur}ms")

        return {
            "ok": rc == 0 and cmd_rc == 0,
            "preset": preset_key,
            "exit_code": cmd_rc,
            "stdout": clean_out,
            "stderr": err.strip(),
            "output": combined,
            "duration_ms": dur,
        }


def shlex_quote(s: str) -> str:
    """POSIX shell quote helper."""
    if not s:
        return "''"
    if re.fullmatch(r"[A-Za-z0-9_@%+=:,./-]+", s):
        return s
    return "'" + s.replace("'", "'\"'\"'") + "'"
