"""Configuration, secure credential storage, mode catalog, and SSE log broker."""

from __future__ import annotations

import collections
import ipaddress
import json
import os
import queue
import re
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any

STUDIO_DIR = Path(__file__).resolve().parent


def resolve_repo_root() -> Path:
    """Resolve the repository/runtime root cleanly across repo runs and .app bundles."""
    env_root = os.environ.get("MAYA_STUDIO_ROOT", "").strip()
    if env_root:
        cand = Path(env_root).expanduser().resolve()
        if cand.is_dir():
            return cand

    parent = STUDIO_DIR.parent
    if (parent / "scripts").is_dir() or (parent / "resources").is_dir():
        return parent

    for ancestor in STUDIO_DIR.parents:
        if (ancestor / "scripts").is_dir() and (ancestor / "studio").is_dir():
            return ancestor
    return parent


REPO_ROOT = resolve_repo_root()
STATIC_DIR = STUDIO_DIR / "static"

STUDIO_FAVICON_SVG: bytes = (
    b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">'
    b'<rect width="64" height="64" rx="14" fill="#0B0F17"/>'
    b'<rect x="12" y="15" width="40" height="8" rx="4" fill="#2563EB"/>'
    b'<rect x="12" y="28" width="40" height="8" rx="4" fill="#3B82F6"/>'
    b'<rect x="12" y="41" width="28" height="8" rx="4" fill="#10B981"/>'
    b'</svg>'
)
CONFIG_DIR = Path.home() / ".config" / "maya-gcs"
CONFIG_DISPLAY_DIR = "~/.config/maya-gcs"
STUDIO_STATE_FILE = CONFIG_DIR / "studio_config.json"

CREDENTIAL_FILES = {
    "hf_token": "hf-token",
    "gcs_key_json": "gcs-key.json",
    "gcs_bucket": "bucket",
    "maya_api_key": "maya-api-key",
    "strata_api_key": "strata-api-key",
}

DEFAULT_HF_REPO = "orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF"

MODES_CATALOG: list[dict[str, Any]] = [
    {
        "id": "b1_pure_hf",
        "name": "Mode B1-Pure · 纯 HF 零云存储",
        "name_en": "Mode B1-Pure · Pure Hugging Face (Zero GCS)",
        "badge": "推荐",
        "recommended": True,
        "short_desc": "MAYA_S2_GCS_DISABLE=1，仅需 HF Token + /mnt/hf FUSE3 + HTTP/2，零云存储月租与零 GCS 跨区流量费。",
        "env": {
            "MAYA_SHARDS57_SOURCE": "hf_fuse",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
            "MAYA_S2_GCS_DISABLE": "1",
        },
        "script_env": {
            "MAYA_SHARDS57_SOURCE": "hf",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
            "MAYA_S2_GCS_DISABLE": "1",
        },
    },
    {
        "id": "b1_hf_fuse",
        "name": "Mode B1 · 同区 GCS 突发加速 (可选)",
        "name_en": "Mode B1 · Same-Region GCS Burst (Optional)",
        "badge": "可选 GCS",
        "recommended": False,
        "short_desc": "Shards 1–4 走 HF Xet，Shards 5–7 走 /mnt/hf；仅在配置与 Colab 同单区域 GCS 桶时启用 >160 突发加速（勿用多区域桶）。",
        "env": {
            "MAYA_SHARDS57_SOURCE": "hf_fuse",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
            "MAYA_S2_GCS_DISABLE": "0",
        },
        "script_env": {
            "MAYA_SHARDS57_SOURCE": "hf",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
            "MAYA_S2_GCS_DISABLE": "0",
        },
    },
    {
        "id": "a_dual_disk",
        "name": "Mode A · A100 双盘直读",
        "name_en": "Mode A · A100 Dual-Disk (/mnt/local-scratch)",
        "badge": "A100",
        "recommended": False,
        "short_desc": "自动检测 /mnt/local-scratch >= 200G，将 Shards 1–3 放副盘释放系统内存，无需 FUSE。",
        "env": {
            "MAYA_SHARDS57_SOURCE": "auto",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
        },
        "script_env": {
            "MAYA_SHARDS57_SOURCE": "auto",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
        },
    },
    {
        "id": "b1_gcs",
        "name": "Mode B1-GCS · 传统 GCS 桶回落",
        "name_en": "Mode B1-GCS · Legacy gcsfuse Bucket",
        "badge": "GCS",
        "recommended": False,
        "short_desc": "挂载 /mnt/gcs gcsfuse + HTTP/2 Range 直连旁路，Shards 1–4 优先从私有 GCS 桶拉取。",
        "env": {
            "MAYA_SHARDS57_SOURCE": "gcsfuse",
            "MAYA_PREFER_GCS_DOWNLOAD": "1",
            "MAYA_S2_GCS_DISABLE": "0",
        },
        "script_env": {
            "MAYA_SHARDS57_SOURCE": "gcs",
            "MAYA_PREFER_GCS_DOWNLOAD": "1",
            "MAYA_S2_GCS_DISABLE": "0",
        },
    },
    {
        "id": "b2_shm",
        "name": "Mode B2 · /dev/shm 内存盘兜底",
        "name_en": "Mode B2 · /dev/shm RAMDisk Fallback",
        "badge": "无凭据",
        "recommended": False,
        "short_desc": "扩容 /dev/shm 至 110G 存放 Shard 00002，无 HF/GCS 凭据时的单盘兼容方案。",
        "env": {
            "MAYA_SHARDS57_SOURCE": "shm",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
        },
        "script_env": {
            "MAYA_SHARDS57_SOURCE": "shm",
            "MAYA_PREFER_GCS_DOWNLOAD": "0",
        },
    },
]

MODES_BY_ID: dict[str, dict[str, Any]] = {m["id"]: m for m in MODES_CATALOG}

DEFAULT_SETTINGS: dict[str, Any] = {
    "mask_urls": True,
    "hf_repo": DEFAULT_HF_REPO,
    "s2_gcs_thresh": 160,
    "s2_local_max": 16,
    "strata_url": "",
    "strata_model": "",
    "strata_max_context": 262144,
    "vision_enabled": True,
    "max_context": 262144,
}


def resolve_mode_env(mode_id: str, settings: dict[str, Any] | None = None, *, for_script: bool = False) -> dict[str, str]:
    """Return environment variable mapping for one of the 5 Maya deployment modes."""
    entry = MODES_BY_ID.get(mode_id) or MODES_BY_ID["b1_pure_hf"]
    key = "script_env" if for_script else "env"
    env = dict(entry[key])
    cfg = settings or {}
    hf_repo = str(cfg.get("hf_repo") or "").strip()
    if hf_repo:
        env["MAYA_HF_REPO"] = hf_repo
    thresh = cfg.get("s2_gcs_thresh")
    if thresh is not None and str(thresh).strip():
        env["MAYA_S2_GCS_THRESH"] = str(int(thresh))
    local_max = cfg.get("s2_local_max")
    if local_max is not None and str(local_max).strip():
        env["MAYA_S2_LOCAL_MAX"] = str(int(local_max))
    return env


def ensure_secure_config_dir() -> Path:
    """Create ~/.config/maya-gcs with strict 0700 permissions."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(CONFIG_DIR, 0o700)
    except OSError:
        pass
    return CONFIG_DIR


def atomic_write_secret(path: Path, content: str) -> None:
    """Write a file atomically inside ~/.config/maya-gcs with 0600 permissions."""
    ensure_secure_config_dir()
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass


def mask_url(url: str) -> str:
    """Mask sensitive tunnel subdomains or non-loopback hostnames for safe display."""
    raw = (url or "").strip()
    if not raw:
        return ""
    try:
        parsed = urllib.parse.urlparse(raw)
        host = parsed.hostname or ""
        if not host:
            return "******"
        scheme = parsed.scheme or "https"
        port_part = f":{parsed.port}" if parsed.port else ""
        if host in ("127.0.0.1", "localhost", "::1"):
            return f"{scheme}://{host}{port_part}{parsed.path}".rstrip("/") if parsed.path else f"{scheme}://{host}{port_part}"
        if host.endswith(".trycloudflare.com"):
            return f"{scheme}://******.trycloudflare.com{port_part}"
        try:
            ip = ipaddress.ip_address(host)
            if ip.version == 4:
                parts = host.split(".")
                return f"{scheme}://{parts[0]}.{parts[1]}.***.***{port_part}"
            return f"{scheme}://[****]{port_part}"
        except ValueError:
            labels = host.split(".")
            if len(labels) >= 2:
                masked_host = "******." + ".".join(labels[1:])
            else:
                masked_host = "******"
            return f"{scheme}://{masked_host}{port_part}"
    except Exception:
        return "https://******"


def mask_email(email: str) -> str:
    """Mask an email address as go***@domain."""
    raw = (email or "").strip()
    if "@" not in raw:
        return "***" if raw else ""
    local, domain = raw.split("@", 1)
    prefix = local[:2] if len(local) >= 2 else local[:1]
    return f"{prefix}***@{domain}"


def mask_bucket(bucket: str) -> str:
    """Mask a GCS bucket name."""
    raw = (bucket or "").strip()
    if not raw:
        return ""
    if len(raw) <= 4:
        return "***"
    return f"{raw[:2]}***{raw[-2:]}"


class LogBroker:
    """Thread-safe ring buffer and SSE pub/sub broker for Studio logs."""

    def __init__(self, maxlen: int = 1000) -> None:
        self._lock = threading.Lock()
        self._entries: collections.deque[dict[str, Any]] = collections.deque(maxlen=maxlen)
        self._subscribers: list[queue.Queue[dict[str, Any]]] = []
        self._next_id = 1

    def emit(self, category: str, level: str, text: str) -> dict[str, Any]:
        """Record a log line and broadcast it to live SSE subscribers."""
        entry = {
            "id": 0,
            "ts": time.strftime("%H:%M:%S"),
            "category": str(category or "system").strip().lower(),
            "level": str(level or "info").strip().lower(),
            "text": str(text),
        }
        with self._lock:
            entry["id"] = self._next_id
            self._next_id += 1
            self._entries.append(entry)
            subs = list(self._subscribers)
        for q in subs:
            try:
                q.put_nowait(entry)
            except queue.Full:
                try:
                    q.get_nowait()
                    q.put_nowait(entry)
                except Exception:
                    pass
        return entry

    def recent(self, limit: int = 200, category: str = "") -> list[dict[str, Any]]:
        """Return the most recent log entries, optionally filtered by category."""
        cat = (category or "").strip().lower()
        with self._lock:
            items = list(self._entries)
        if cat and cat != "all":
            items = [item for item in items if item.get("category") == cat]
        if limit > 0:
            items = items[-limit:]
        return items

    def subscribe(self, tail: int = 60) -> tuple[list[dict[str, Any]], queue.Queue[dict[str, Any]]]:
        """Register a new SSE subscriber queue and return recent history atomically."""
        q: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=500)
        with self._lock:
            items = list(self._entries)[-tail:] if tail > 0 else []
            self._subscribers.append(q)
        return items, q

    def unsubscribe(self, q: queue.Queue[dict[str, Any]]) -> None:
        """Remove an SSE subscriber queue."""
        with self._lock:
            try:
                self._subscribers.remove(q)
            except ValueError:
                pass


class ConfigStore:
    """Manages persistent Studio config and ~/.config/maya-gcs/ credentials."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self.selected_gpu: str = "G4"
        self.selected_session: str = "easycolab"
        self.engine_kind: str = "maya"
        self.maya_mode: str = "b1_pure_hf"
        self.upstream_url: str = ""
        self.settings: dict[str, Any] = dict(DEFAULT_SETTINGS)
        self._load_state()

    def _load_state(self) -> None:
        if not STUDIO_STATE_FILE.is_file():
            return
        try:
            raw = json.loads(STUDIO_STATE_FILE.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                return
            if isinstance(raw.get("selected_gpu"), str) and raw["selected_gpu"].strip():
                self.selected_gpu = raw["selected_gpu"].strip().upper()
            if isinstance(raw.get("selected_session"), str) and raw["selected_session"].strip():
                self.selected_session = raw["selected_session"].strip()
            if raw.get("engine_kind") in ("maya", "strata"):
                self.engine_kind = raw["engine_kind"]
            if raw.get("maya_mode") in MODES_BY_ID:
                self.maya_mode = raw["maya_mode"]
            if isinstance(raw.get("upstream_url"), str):
                self.upstream_url = raw["upstream_url"].strip()
            saved_settings = raw.get("settings")
            if isinstance(saved_settings, dict):
                self.update_settings(saved_settings, persist=False)
        except Exception:
            pass

    def _save_state(self) -> None:
        with self._lock:
            payload = {
                "selected_gpu": self.selected_gpu,
                "selected_session": self.selected_session,
                "engine_kind": self.engine_kind,
                "maya_mode": self.maya_mode,
                "upstream_url": self.upstream_url,
                "settings": dict(self.settings),
            }
        try:
            atomic_write_secret(STUDIO_STATE_FILE, json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
        except OSError:
            pass

    def update_settings(self, patch: dict[str, Any], *, persist: bool = True) -> dict[str, Any]:
        """Validate and merge settings fields."""
        if not isinstance(patch, dict):
            return dict(self.settings)
        with self._lock:
            if "mask_urls" in patch:
                self.settings["mask_urls"] = bool(patch["mask_urls"])
            if "hf_repo" in patch and isinstance(patch["hf_repo"], str):
                val = patch["hf_repo"].strip()
                if val:
                    self.settings["hf_repo"] = val
            for int_key, low, high in (
                ("s2_gcs_thresh", 0, 65536),
                ("s2_local_max", 0, 1024),
                ("strata_max_context", 1024, 2097152),
                ("max_context", 1024, 2097152),
            ):
                if int_key in patch and patch[int_key] is not None and str(patch[int_key]).strip() != "":
                    try:
                        parsed = int(patch[int_key])
                        self.settings[int_key] = max(low, min(high, parsed))
                    except (TypeError, ValueError):
                        pass
            if "strata_url" in patch and isinstance(patch["strata_url"], str):
                self.settings["strata_url"] = patch["strata_url"].strip().rstrip("/")
            if "strata_model" in patch and isinstance(patch["strata_model"], str):
                self.settings["strata_model"] = patch["strata_model"].strip()
            if "vision_enabled" in patch:
                self.settings["vision_enabled"] = bool(patch["vision_enabled"])
            snapshot = dict(self.settings)
        if persist:
            self._save_state()
        return snapshot

    def set_selection(
        self,
        *,
        gpu: str | None = None,
        session: str | None = None,
        engine_kind: str | None = None,
        maya_mode: str | None = None,
        upstream_url: str | None = None,
    ) -> None:
        """Persist core selection and active upstream URL."""
        with self._lock:
            if gpu is not None and gpu.strip():
                self.selected_gpu = gpu.strip().upper()
            if session is not None and session.strip():
                self.selected_session = session.strip()
            if engine_kind in ("maya", "strata"):
                self.engine_kind = engine_kind
            if maya_mode in MODES_BY_ID:
                self.maya_mode = maya_mode
            if upstream_url is not None:
                self.upstream_url = upstream_url.strip().rstrip("/")
        self._save_state()

    def get_settings(self) -> dict[str, Any]:
        with self._lock:
            return dict(self.settings)

    def read_credential_file(self, key: str) -> str:
        """Read a credential file from ~/.config/maya-gcs/ if present."""
        fname = CREDENTIAL_FILES.get(key)
        if not fname:
            return ""
        path = CONFIG_DIR / fname
        if not path.is_file():
            return ""
        try:
            return path.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def save_credentials(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Validate and persist credential files in ~/.config/maya-gcs/ (mode 0600)."""
        if not isinstance(payload, dict):
            raise ValueError("Invalid JSON payload")

        ensure_secure_config_dir()

        def _handle_clear(clear_key: str, cred_key: str) -> None:
            if payload.get(clear_key) is True:
                target = CONFIG_DIR / CREDENTIAL_FILES[cred_key]
                if target.exists():
                    target.unlink()

        _handle_clear("clear_hf_token", "hf_token")
        _handle_clear("clear_gcs_key", "gcs_key_json")
        _handle_clear("clear_gcs_bucket", "gcs_bucket")
        _handle_clear("clear_maya_api_key", "maya_api_key")
        _handle_clear("clear_strata_api_key", "strata_api_key")

        hf_token = payload.get("hf_token")
        if isinstance(hf_token, str) and hf_token.strip():
            atomic_write_secret(CONFIG_DIR / CREDENTIAL_FILES["hf_token"], hf_token.strip() + "\n")

        gcs_bucket = payload.get("gcs_bucket")
        if isinstance(gcs_bucket, str) and gcs_bucket.strip():
            clean_bucket = re.sub(r"^gs://", "", gcs_bucket.strip()).strip("/")
            atomic_write_secret(CONFIG_DIR / CREDENTIAL_FILES["gcs_bucket"], clean_bucket + "\n")

        gcs_key_raw = payload.get("gcs_key_json")
        if isinstance(gcs_key_raw, dict):
            gcs_key_raw = json.dumps(gcs_key_raw, indent=2)
        if isinstance(gcs_key_raw, str) and gcs_key_raw.strip():
            try:
                parsed = json.loads(gcs_key_raw.strip())
            except json.JSONDecodeError as exc:
                raise ValueError(f"gcs_key_json 不是合法 JSON: {exc}") from exc
            if not isinstance(parsed, dict) or not parsed:
                raise ValueError("gcs_key_json 必须是服务账号 JSON 对象")
            atomic_write_secret(
                CONFIG_DIR / CREDENTIAL_FILES["gcs_key_json"],
                json.dumps(parsed, indent=2) + "\n",
            )

        maya_key = payload.get("maya_api_key")
        if isinstance(maya_key, str) and maya_key.strip():
            atomic_write_secret(CONFIG_DIR / CREDENTIAL_FILES["maya_api_key"], maya_key.strip() + "\n")

        strata_key = payload.get("strata_api_key")
        if isinstance(strata_key, str) and strata_key.strip():
            atomic_write_secret(CONFIG_DIR / CREDENTIAL_FILES["strata_api_key"], strata_key.strip() + "\n")

        return self.credentials_status()

    def credentials_status(self) -> dict[str, Any]:
        """Return safe non-secret credential availability metadata."""
        hf_exists = (CONFIG_DIR / CREDENTIAL_FILES["hf_token"]).is_file() and bool(self.read_credential_file("hf_token"))
        gcs_key_exists = (CONFIG_DIR / CREDENTIAL_FILES["gcs_key_json"]).is_file() and bool(
            self.read_credential_file("gcs_key_json")
        )
        gcs_bucket = self.read_credential_file("gcs_bucket")
        maya_key_exists = (CONFIG_DIR / CREDENTIAL_FILES["maya_api_key"]).is_file() and bool(
            self.read_credential_file("maya_api_key")
        )
        strata_key_exists = (CONFIG_DIR / CREDENTIAL_FILES["strata_api_key"]).is_file() and bool(
            self.read_credential_file("strata_api_key")
        )
        pi_models = Path.home() / ".pi" / "agent" / "models.json"
        return {
            "config_dir": CONFIG_DISPLAY_DIR,
            "has_hf_token": hf_exists,
            "has_gcs_key": gcs_key_exists,
            "gcs_bucket": gcs_bucket,
            "has_maya_key": maya_key_exists,
            "has_strata_key": strata_key_exists,
            "pi_sync_available": pi_models.is_file(),
        }
