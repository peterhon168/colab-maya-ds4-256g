"""Studio control-plane HTTP server (127.0.0.1:18765), REST APIs, and SSE log stream."""

from __future__ import annotations

import http.server
import json
import mimetypes
import os
import pwd
import queue
import socketserver
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from . import __version__
from .colab_manager import ColabManager
from .config_store import (
    MODES_CATALOG,
    STATIC_DIR,
    STUDIO_FAVICON_SVG,
    ConfigStore,
    LogBroker,
    atomic_write_secret,
    mask_url,
)
from .engine_proxy import EngineProxyServer, fetch_engine_telemetry, send_chat_probe

mimetypes.add_type("application/javascript", ".js")
mimetypes.add_type("text/css", ".css")
mimetypes.add_type("image/svg+xml", ".svg")
mimetypes.add_type("font/woff2", ".woff2")


def _fallback_index_html(studio_port: int, proxy_port: int) -> bytes:
    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Maya · Strata Studio</title>
  <style>
    body {{
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      background: #0b0f17; color: #e2e8f0;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    }}
    .card {{
      max-width: 520px; background: #111826;
      border: 1px solid rgba(148, 163, 184, 0.16);
      border-radius: 14px; padding: 26px 28px;
    }}
    h1 {{ margin: 0 0 10px; font-size: 20px; }}
    p {{ margin: 0 0 10px; color: #94a3b8; font-size: 14px; line-height: 1.6; }}
    code {{
      background: rgba(15, 23, 42, 0.8); padding: 2px 6px; border-radius: 5px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px;
    }}
  </style>
</head>
<body>
  <div class="card">
    <h1>Maya · Strata Studio 后端控制面已就绪</h1>
    <p>前端静态页面 <code>studio/static/index.html</code> 尚未放置，控制面 API 与同源代理已正常工作。</p>
    <p>Control Plane: <code>http://127.0.0.1:{studio_port}/api/studio/state</code></p>
    <p style="margin-bottom: 0;">Proxy Gateway: <code>http://127.0.0.1:{proxy_port}/</code></p>
  </div>
</body>
</html>
"""
    return html.encode("utf-8")


def _resolve_pi_web_url() -> str:
    """Resolve optional local pi-web URL while isolating temporary HOME test runs."""
    raw = os.environ.get("PI_WEB_URL")
    if raw is not None:
        cleaned = raw.strip().rstrip("/")
        if cleaned.lower() in ("", "off", "0", "false", "none"):
            return ""
        return cleaned
    try:
        real_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
        if Path.home().resolve() != real_home:
            return ""
    except Exception:
        pass
    return "http://127.0.0.1:30141"


class StudioRuntime:
    """Owns Studio state, background telemetry polling, Colab bridge, and reverse proxy."""

    def _resolve_engine_api_key(self, kind: str) -> str:
        cred_key = "strata_api_key" if kind == "strata" else "maya_api_key"
        return self.config.read_credential_file(cred_key)

    def __init__(
        self,
        *,
        host: str = "127.0.0.1",
        studio_port: int = 18765,
        proxy_port: int = 18766,
    ) -> None:
        self.host = host
        self.studio_port = studio_port
        self.proxy_port = proxy_port

        self.logs = LogBroker()
        self.config = ConfigStore()

        initial_api_key = self._resolve_engine_api_key(self.config.engine_kind)
        self.proxy = EngineProxyServer(
            host=host,
            proxy_port=proxy_port,
            studio_port=studio_port,
            logs=self.logs,
            initial_upstream=self.config.upstream_url,
            initial_kind=self.config.engine_kind,
            initial_api_key=initial_api_key,
        )
        self.colab = ColabManager(
            config=self.config,
            logs=self.logs,
            proxy=self.proxy,
            on_telemetry_refresh=self.refresh_telemetry_now,
        )
        self.proxy.deployment_getter = self.colab.get_deployment_snapshot

        self._tel_lock = threading.RLock()
        self._tel_fail_streak: int = 0
        self._tel_upstream: str = ""
        self._telemetry: dict[str, Any] = {
            "online": False,
            "loaded": False,
            "has_metrics": False,
            "model_id": "",
            "telemetry": {
                "requests_total": None,
                "last_prefill_tok_s": None,
                "last_decode_tok_s": None,
                "vram_hit_pct": None,
                "busy": False,
                "queued": 0,
                "recent_requests": [],
            },
        }
        self._stop_ev = threading.Event()
        self._bg_thread: threading.Thread | None = None

    def start_background(self, *, auto_attach: bool = False) -> None:
        self.proxy.start()
        self.logs.emit("system", "info", f"Maya · Strata Studio 控制面启动中 (:{self.studio_port})")

        def _bg_init() -> None:
            try:
                self.colab.refresh_auth_status(log_event=False)
                if auto_attach:
                    sess = self.config.selected_session or "easycolab"
                    sessions = self.colab.get_colab_snapshot().get("sessions") or []
                    has_sess = any(isinstance(s, dict) and s.get("name") == sess for s in sessions)
                    if has_sess or self.colab.is_keepalive_running(sess):
                        self.colab.attach(session=sess, auto_keepalive=True)
                self.refresh_telemetry_now()
            except Exception as exc:
                self.logs.emit("system", "warn", f"初始化探测异常: {exc}")

            last_colab_sync = time.monotonic()
            while not self._stop_ev.wait(4.0):
                try:
                    self.refresh_telemetry_now()
                    now_m = time.monotonic()
                    if now_m - last_colab_sync >= 45.0:
                        self.colab.refresh_auth_status(log_event=False)
                        last_colab_sync = now_m
                except Exception:
                    pass

        self._bg_thread = threading.Thread(target=_bg_init, name="studio-bg-monitor", daemon=True)
        self._bg_thread.start()

    def stop_background(self) -> None:
        self._stop_ev.set()
        self.proxy.stop()

    def refresh_telemetry_now(self) -> dict[str, Any]:
        upstream, kind, api_key = self.proxy.state.snapshot()
        settings = self.config.get_settings()
        snap = fetch_engine_telemetry(
            upstream,
            engine_kind=kind,
            api_key=api_key,
            strata_model=str(settings.get("strata_model") or ""),
            timeout=6.0,
        )
        with self._tel_lock:
            same_upstream = bool(upstream) and (upstream == self._tel_upstream)
            if not upstream or not same_upstream:
                self._tel_upstream = upstream
                self._tel_fail_streak = 0
                self._telemetry = snap
            elif snap.get("online"):
                self._tel_fail_streak = 0
                prev_tel = self._telemetry.get("telemetry") if isinstance(self._telemetry.get("telemetry"), dict) else {}
                prev_has_data = prev_tel.get("requests_total") is not None or bool(prev_tel.get("recent_requests"))
                if not snap.get("has_metrics") and self._telemetry.get("online") and prev_has_data:
                    # /health 通了但 /metrics 偶发超时时保留上次遥测，防止 KPI 与请求表闪回 "--"
                    snap["telemetry"] = dict(prev_tel)
                self._telemetry = snap
            else:
                if self._telemetry.get("online"):
                    self._tel_fail_streak += 1
                    if self._tel_fail_streak < 3:
                        # 同一上游偶发单/双次隧道抖动超时，暂保在线与历史遥测，连续 3 次失联才判离线
                        effective = dict(self._telemetry)
                        effective["telemetry"] = dict(self._telemetry.get("telemetry") or {})
                        return effective
                self._telemetry = snap
        if snap.get("online") and (kind == "strata" or snap.get("loaded")):
            self.colab.mark_warming_ready_if_idle_deploy()
        return snap

    def get_telemetry_snapshot(self) -> dict[str, Any]:
        with self._tel_lock:
            return {
                "online": self._telemetry["online"],
                "loaded": self._telemetry["loaded"],
                "model_id": self._telemetry["model_id"],
                "telemetry": dict(self._telemetry["telemetry"]),
            }

    def build_state_payload(self) -> dict[str, Any]:
        upstream, kind, api_key = self.proxy.state.snapshot()
        has_api_key = bool(api_key or self._resolve_engine_api_key(kind))
        tel = self.get_telemetry_snapshot()
        settings = self.config.get_settings()
        return {
            "ok": True,
            "version": __version__,
            "ports": {
                "studio": self.studio_port,
                "proxy": self.proxy_port,
            },
            "colab": self.colab.get_colab_snapshot(),
            "deployment": self.colab.get_deployment_snapshot(),
            "engine": {
                "kind": kind,
                "mode": self.config.maya_mode,
                "online": tel["online"],
                "loaded": tel["loaded"],
                "upstream_url": upstream,
                "upstream_masked": mask_url(upstream),
                "proxy_url": f"http://127.0.0.1:{self.proxy_port}",
                "openai_base_url": f"http://127.0.0.1:{self.proxy_port}/v1",
                "has_api_key": has_api_key,
                "model_id": tel["model_id"],
                "telemetry": tel["telemetry"],
            },
            "credentials": self.config.credentials_status(),
            "modes_catalog": MODES_CATALOG,
            "settings": settings,
        }

    def configure_engine(self, body: dict[str, Any]) -> dict[str, Any]:
        kind = body.get("kind") or self.config.engine_kind
        if kind not in ("maya", "strata"):
            raise ValueError(f"不支持的引擎类型: {kind}")

        mode = body.get("mode") or self.config.maya_mode
        settings_patch = body.get("settings")
        if isinstance(settings_patch, dict):
            self.config.update_settings(settings_patch)

        if isinstance(body.get("selected_gpu"), str) and body["selected_gpu"].strip():
            self.config.set_selection(gpu=body["selected_gpu"].strip())
        if isinstance(body.get("selected_session"), str) and body["selected_session"].strip():
            self.config.set_selection(session=body["selected_session"].strip())

        if "upstream_url" in body and isinstance(body["upstream_url"], str):
            upstream = body["upstream_url"].strip().rstrip("/")
        elif kind == "strata":
            upstream = str(self.config.get_settings().get("strata_url") or self.config.upstream_url or "").strip().rstrip("/")
        else:
            upstream = self.config.upstream_url

        if kind == "strata" and upstream:
            self.config.update_settings({"strata_url": upstream})

        api_key_arg = body.get("api_key")
        cred_clear_key = "clear_strata_api_key" if kind == "strata" else "clear_maya_api_key"
        cred_save_key = "strata_api_key" if kind == "strata" else "maya_api_key"
        if body.get("clear_api_key") is True:
            api_key = ""
            self.config.save_credentials({cred_clear_key: True})
        elif isinstance(api_key_arg, str) and api_key_arg.strip():
            api_key = api_key_arg.strip()
            self.config.save_credentials({cred_save_key: api_key})
        else:
            api_key = self._resolve_engine_api_key(kind)

        self.config.set_selection(engine_kind=kind, maya_mode=mode, upstream_url=upstream)
        self.proxy.set_upstream(upstream, engine_kind=kind, api_key=api_key)
        self.refresh_telemetry_now()

        masked = mask_url(upstream) if upstream else "(未挂载)"
        self.logs.emit("proxy", "info", f"引擎配置已切换: kind={kind}, mode={mode}, upstream={masked}")
        return self.build_state_payload()

    def probe_engine(self, body: dict[str, Any]) -> dict[str, Any]:
        prompt = str(body.get("prompt") or "请用一句话自我介绍并确认推理服务正常。").strip()
        if not prompt:
            prompt = "Hello"
        try:
            max_tokens = int(body.get("max_tokens") or 128)
        except (TypeError, ValueError):
            max_tokens = 128

        upstream, kind, api_key = self.proxy.state.snapshot()
        if not upstream:
            return {"ok": False, "error": "尚未挂载上游推理引擎，请先 attach 或配置 Strata URL"}

        tel = self.get_telemetry_snapshot()
        settings = self.config.get_settings()
        model_id = str(body.get("model") or tel.get("model_id") or settings.get("strata_model") or "")
        self.logs.emit("cmd", "info", f"发起对话探针 ({kind}, max_tokens={max_tokens})...")
        res = send_chat_probe(
            proxy_port=self.proxy_port,
            prompt=prompt,
            max_tokens=max_tokens,
            model_id=model_id,
            api_key=api_key,
            timeout=120.0,
        )
        self.refresh_telemetry_now()
        if res.get("ok"):
            self.logs.emit(
                "cmd",
                "success",
                f"探针成功: model={res.get('model')}, elapsed={res.get('elapsed_ms')}ms, tok/s={res.get('tok_s')}",
            )
        else:
            self.logs.emit("cmd", "error", f"探针失败: {res.get('error')}")
        return res

    def sync_clients(self, body: dict[str, Any]) -> dict[str, Any]:
        target = str(body.get("target") or "pi").strip().lower()
        use_local_proxy = body.get("use_local_proxy", True) is not False

        upstream, kind, proxy_api_key = self.proxy.state.snapshot()
        active_api_key = proxy_api_key or self._resolve_engine_api_key(kind)
        tel = self.get_telemetry_snapshot()
        settings = self.config.get_settings()

        if use_local_proxy or not upstream:
            base_url = f"http://127.0.0.1:{self.proxy_port}/v1"
        else:
            base_url = f"{upstream.rstrip('/')}/v1"

        model_id = (
            str(tel.get("model_id") or "").strip()
            or str(settings.get("strata_model") or "").strip()
            or ("deepseek-v4.1-flash-abliterated" if kind == "maya" else "strata-model")
        )
        max_ctx = int(settings.get("strata_max_context") if kind == "strata" else settings.get("max_context") or 262144)

        pi_updated = False
        pi_web_synced = False
        provider_key = "A100" if kind == "maya" else "strata-studio"
        pi_api_key = active_api_key if (not use_local_proxy and active_api_key) else ""

        pi_path = Path.home() / ".pi" / "agent" / "models.json"
        if target in ("pi", "all") and pi_path.is_file():
            try:
                cfg = json.loads(pi_path.read_text(encoding="utf-8"))
                if not isinstance(cfg, dict):
                    cfg = {}
                providers = cfg.setdefault("providers", {})
                if kind == "maya" and "A100" not in providers:
                    provider_key = "maya-studio"

                existing = providers.get(provider_key)
                if not isinstance(existing, dict):
                    existing = {
                        "api": "openai-completions",
                        "baseUrl": base_url,
                        "apiKey": pi_api_key or "EMPTY",
                        "models": [
                            {
                                "id": model_id,
                                "reasoning": True,
                                "contextWindow": max_ctx,
                                "maxTokens": 65536,
                                "input": ["text", "image"],
                            }
                        ],
                    }
                    providers[provider_key] = existing
                else:
                    existing["baseUrl"] = base_url
                    if pi_api_key:
                        existing["apiKey"] = pi_api_key
                    models = existing.setdefault("models", [])
                    if not models:
                        models.append(
                            {
                                "id": model_id,
                                "reasoning": True,
                                "contextWindow": max_ctx,
                                "maxTokens": 65536,
                                "input": ["text", "image"],
                            }
                        )
                    else:
                        for m in models:
                            if isinstance(m, dict):
                                m["maxTokens"] = max(int(m.get("maxTokens") or 0), 65536)
                                m["contextWindow"] = max(int(m.get("contextWindow") or 0), max_ctx)
                                inp = list(m.get("input") or ["text"])
                                if "image" not in inp:
                                    inp.append("image")
                                m["input"] = inp

                atomic_write_secret(pi_path, json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
                pi_updated = True
                self.logs.emit("system", "success", f"已同步 ~/.pi/agent/models.json (provider={provider_key}, baseUrl={base_url})")

                # Notify pi-web if running and not disabled / isolated (bypassing any system HTTP_PROXY)
                pi_web_url = _resolve_pi_web_url()
                if pi_web_url:
                    try:
                        no_proxy_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                        req1 = urllib.request.Request(
                            f"{pi_web_url}/api/models-config",
                            data=json.dumps(cfg).encode("utf-8"),
                            headers={"Content-Type": "application/json"},
                            method="PUT",
                        )
                        no_proxy_opener.open(req1, timeout=2.5).read()
                        req2 = urllib.request.Request(
                            f"{pi_web_url}/api/models/refresh",
                            data=b"{}",
                            headers={"Content-Type": "application/json"},
                            method="POST",
                        )
                        no_proxy_opener.open(req2, timeout=2.5).read()
                        pi_web_synced = True
                        self.logs.emit("system", "info", f"已通知 pi-web ({pi_web_url}) 刷新模型配置")
                    except Exception:
                        pass
            except Exception as exc:
                self.logs.emit("system", "warn", f"更新 ~/.pi/agent/models.json 失败: {exc}")

        snippet_base = base_url if use_local_proxy else (
            mask_url(upstream).rstrip("/") + "/v1" if settings.get("mask_urls") and upstream else base_url
        )
        root_snippet_base = snippet_base[:-3] if snippet_base.endswith("/v1") else snippet_base
        snippet_key = (
            "sk-maya-******"
            if (not use_local_proxy and active_api_key and settings.get("mask_urls", True))
            else (active_api_key if (not use_local_proxy and active_api_key) else "EMPTY")
        )

        snippets = {
            "base_url": snippet_base,
            "model_id": model_id,
            "pi": json.dumps(
                {
                    "providers": {
                        provider_key: {
                            "api": "openai-completions",
                            "baseUrl": snippet_base,
                            "apiKey": snippet_key,
                            "models": [
                                {
                                    "id": model_id,
                                    "reasoning": True,
                                    "contextWindow": max_ctx,
                                    "maxTokens": 65536,
                                    "input": ["text", "image"],
                                }
                            ],
                        }
                    }
                },
                indent=2,
            ),
            "openai_python": (
                "from openai import OpenAI\n\n"
                f'client = OpenAI(base_url="{snippet_base}", api_key="{snippet_key}")\n'
                "resp = client.chat.completions.create(\n"
                f'    model="{model_id}",\n'
                '    messages=[{"role": "user", "content": "Hello"}],\n'
                "    max_tokens=1024,\n"
                ")\n"
                "print(resp.choices[0].message.content)"
            ),
            "cursor": (
                f"Override OpenAI Base URL: {snippet_base}\n"
                f"Model ID: {model_id}\n"
                f"API Key: {snippet_key}"
            ),
            "claude_code": (
                f'export ANTHROPIC_BASE_URL="{root_snippet_base}"\n'
                f'export ANTHROPIC_AUTH_TOKEN="{snippet_key}"\n'
                f'export ANTHROPIC_MODEL="{model_id}"'
            ),
            "curl": (
                f'curl -sS "{snippet_base}/chat/completions" \\\n'
                '  -H "Content-Type: application/json" \\\n'
                + (f'  -H "Authorization: Bearer {snippet_key}" \\\n' if snippet_key != "EMPTY" else "")
                + f'  -d \'{{"model":"{model_id}","messages":[{{"role":"user","content":"Hi"}}],"max_tokens":128}}\''
            ),
        }

        updated_files: list[str] = []
        if pi_updated:
            updated_files.append("~/.pi/agent/models.json")
        if pi_web_synced:
            updated_files.append("pi-web:30141")
        if pi_updated:
            msg = f"已同步 Pi 配置 (provider={provider_key})"
        elif target in ("pi", "all"):
            msg = "已生成客户端配置片段（本机未检测到 ~/.pi/agent/models.json）"
        else:
            msg = "已生成客户端配置片段"

        return {
            "ok": True,
            "target": target,
            "use_local_proxy": use_local_proxy,
            "base_url": snippet_base,
            "pi_updated": pi_updated,
            "pi_web_synced": pi_web_synced,
            "provider_key": provider_key,
            "updated_files": updated_files,
            "message": msg,
            "snippets": snippets,
        }


class _StudioHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        host, port = self.socket.getsockname()[:2]
        self.server_name = str(host)
        self.server_port = int(port)


class StudioServer:
    """HTTP + SSE server for Maya · Strata Studio (127.0.0.1:18765)."""

    def __init__(self, runtime: StudioRuntime) -> None:
        self.runtime = runtime
        self._httpd: _StudioHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._httpd is not None:
            return
        rt = self.runtime
        static_root = STATIC_DIR.resolve()

        class StudioHandler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
                return

            def _send_bytes(self, status: int, content_type: str, body: bytes, *, cache_control: str = "no-store") -> None:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", cache_control)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def _send_json(self, status: int, payload: dict[str, Any]) -> None:
                raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                self._send_bytes(status, "application/json; charset=utf-8", raw)

            def _read_json_body(self) -> tuple[dict[str, Any] | None, str]:
                try:
                    length = int(self.headers.get("Content-Length") or "0")
                except ValueError:
                    return None, "Invalid Content-Length"
                if length <= 0:
                    return {}, ""
                raw = self.rfile.read(length)
                try:
                    parsed = json.loads(raw.decode("utf-8"))
                except Exception as exc:
                    return None, f"Invalid JSON: {exc}"
                if not isinstance(parsed, dict):
                    return None, "JSON body must be an object"
                return parsed, ""

            def _serve_static(self, rel_path: str) -> None:
                clean = urllib.parse.unquote(rel_path).lstrip("/")
                if not clean or "\x00" in clean or "\\" in clean:
                    self._send_json(404, {"ok": False, "error": "Not found"})
                    return
                candidate = (static_root / clean).resolve()
                if not candidate.is_relative_to(static_root) or not candidate.is_file():
                    self._send_json(404, {"ok": False, "error": "Not found"})
                    return
                ctype, _ = mimetypes.guess_type(str(candidate))
                if not ctype:
                    ctype = "application/octet-stream"
                if ctype.startswith("text/") or ctype in ("application/javascript", "application/json"):
                    ctype = f"{ctype}; charset=utf-8"
                self._send_bytes(200, ctype, candidate.read_bytes(), cache_control="no-cache")

            def _serve_logs_stream(self) -> None:
                parsed = urllib.parse.urlparse(self.path)
                qs = urllib.parse.parse_qs(parsed.query)
                try:
                    tail = int((qs.get("tail") or ["60"])[0])
                except ValueError:
                    tail = 60
                history, q = rt.logs.subscribe(tail=max(0, min(500, tail)))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                try:
                    for item in history:
                        line = f"data: {json.dumps(item, ensure_ascii=False)}\n\n".encode("utf-8")
                        self.wfile.write(line)
                    self.wfile.flush()
                    while True:
                        try:
                            item = q.get(timeout=15.0)
                            line = f"data: {json.dumps(item, ensure_ascii=False)}\n\n".encode("utf-8")
                            self.wfile.write(line)
                            self.wfile.flush()
                        except queue.Empty:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
                    pass
                finally:
                    rt.logs.unsubscribe(q)

            def do_GET(self) -> None:
                parsed = urllib.parse.urlparse(self.path)
                path = parsed.path

                if path in ("/", "/index.html"):
                    index_file = static_root / "index.html"
                    if index_file.is_file():
                        self._send_bytes(200, "text/html; charset=utf-8", index_file.read_bytes(), cache_control="no-cache")
                    else:
                        self._send_bytes(
                            200,
                            "text/html; charset=utf-8",
                            _fallback_index_html(rt.studio_port, rt.proxy_port),
                        )
                    return

                if path.startswith("/static/"):
                    self._serve_static(path[len("/static/"):])
                    return

                if path == "/favicon.ico":
                    fav_file = static_root / "favicon.ico"
                    if fav_file.is_file():
                        self._send_bytes(200, "image/x-icon", fav_file.read_bytes(), cache_control="public, max-age=86400")
                    else:
                        self._send_bytes(200, "image/svg+xml; charset=utf-8", STUDIO_FAVICON_SVG, cache_control="public, max-age=86400")
                    return

                if path == "/api/studio/state":
                    self._send_json(200, rt.build_state_payload())
                    return

                if path == "/api/studio/logs":
                    qs = urllib.parse.parse_qs(parsed.query)
                    cat = (qs.get("category") or [""])[0]
                    try:
                        limit = int((qs.get("limit") or ["200"])[0])
                    except ValueError:
                        limit = 200
                    self._send_json(200, {"ok": True, "logs": rt.logs.recent(limit=limit, category=cat)})
                    return

                if path == "/api/studio/logs/stream":
                    self._serve_logs_stream()
                    return

                self._send_json(404, {"ok": False, "error": f"Unknown route: {path}"})

            def do_HEAD(self) -> None:
                self.do_GET()

            def do_OPTIONS(self) -> None:
                self.send_response(204)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_POST(self) -> None:
                path = urllib.parse.urlparse(self.path).path
                body, err = self._read_json_body()
                if body is None:
                    self._send_json(400, {"ok": False, "error": err})
                    return

                try:
                    if path == "/api/studio/colab/refresh":
                        snap = rt.colab.refresh_auth_status(log_event=True)
                        rt.refresh_telemetry_now()
                        self._send_json(200, {"ok": True, "colab": snap, "state": rt.build_state_payload()})
                        return

                    if path == "/api/studio/colab/auth-url":
                        res = rt.colab.auth_url()
                        self._send_json(200 if res.get("ok") else 400, res)
                        return

                    if path == "/api/studio/colab/auth-code":
                        res = rt.colab.auth_code(str(body.get("code") or ""))
                        self._send_json(200 if res.get("ok") else 400, res)
                        return

                    if path == "/api/studio/colab/auth-logout":
                        res = rt.colab.auth_logout()
                        self._send_json(200, res)
                        return

                    if path == "/api/studio/colab/attach":
                        res = rt.colab.attach(
                            session=str(body.get("session") or ""),
                            engine_kind=str(body.get("engine_kind") or ""),
                            auto_keepalive=bool(body.get("auto_keepalive", True)),
                        )
                        if res.get("ok"):
                            res["state"] = rt.build_state_payload()
                        self._send_json(200 if res.get("ok") else 400, res)
                        return

                    if path == "/api/studio/colab/deploy":
                        res = rt.colab.deploy(
                            gpu=str(body.get("gpu") or "G4"),
                            session=str(body.get("session") or "easycolab"),
                            engine_kind=str(body.get("engine_kind") or "maya"),
                            mode=str(body.get("mode") or rt.config.maya_mode or "b1_pure_hf"),
                            settings=body.get("settings") if isinstance(body.get("settings"), dict) else None,
                        )
                        self._send_json(200 if res.get("ok") else 400, res)
                        return

                    if path == "/api/studio/colab/keepalive":
                        res = rt.colab.keepalive(
                            enabled=bool(body.get("enabled", True)),
                            session=str(body.get("session") or ""),
                            interval_sec=int(body.get("interval_sec") or 720),
                        )
                        self._send_json(200 if res.get("ok") else 400, res)
                        return

                    if path == "/api/studio/colab/stop":
                        if body.get("confirm") is not True:
                            self._send_json(
                                400,
                                {"ok": False, "error": "Confirmation required: pass {\"confirm\": true}"},
                            )
                            return
                        res = rt.colab.stop_session(
                            session=str(body.get("session") or ""),
                            confirm=True,
                        )
                        self._send_json(200 if res.get("ok") else 400, res)
                        return

                    if path == "/api/studio/engine/configure":
                        st = rt.configure_engine(body)
                        self._send_json(200, {"ok": True, "state": st})
                        return

                    if path == "/api/studio/engine/probe":
                        res = rt.probe_engine(body)
                        self._send_json(200 if res.get("ok") else 502 if res.get("status_code") == 502 else 400, res)
                        return

                    if path == "/api/studio/engine/sync-clients":
                        res = rt.sync_clients(body)
                        self._send_json(200 if res.get("ok") else 400, res)
                        return

                    if path == "/api/studio/credentials":
                        creds = rt.config.save_credentials(body)
                        upstream, kind, _ = rt.proxy.state.snapshot()
                        if upstream or body.get("maya_api_key") or body.get("clear_maya_api_key") or body.get("strata_api_key") or body.get("clear_strata_api_key"):
                            rt.proxy.set_upstream(
                                upstream,
                                engine_kind=kind,
                                api_key=rt._resolve_engine_api_key(kind),
                            )
                            if upstream:
                                rt.refresh_telemetry_now()
                        rt.logs.emit("system", "info", "已安全更新 ~/.config/maya-gcs/ 凭据 (chmod 0600)")
                        self._send_json(200, {"ok": True, "credentials": creds, "state": rt.build_state_payload()})
                        return

                    if path == "/api/studio/settings":
                        if isinstance(body.get("settings"), dict):
                            rt.config.update_settings(body["settings"])
                        else:
                            rt.config.update_settings(body)
                        if isinstance(body.get("selected_gpu"), str):
                            rt.config.set_selection(gpu=body["selected_gpu"])
                        if isinstance(body.get("selected_session"), str):
                            rt.config.set_selection(session=body["selected_session"])
                        self._send_json(200, {"ok": True, "state": rt.build_state_payload()})
                        return

                    if path == "/api/studio/cmd/exec":
                        res = rt.colab.exec_command(
                            preset=str(body.get("preset") or "custom"),
                            command=str(body.get("command") or ""),
                            session=str(body.get("session") or ""),
                        )
                        status = 200 if res.get("ok") else (400 if res.get("exit_code") == 400 else 200)
                        self._send_json(status, res)
                        return

                    self._send_json(404, {"ok": False, "error": f"Unknown API route: {path}"})
                except ValueError as exc:
                    self._send_json(400, {"ok": False, "error": str(exc)})
                except Exception as exc:
                    self._send_json(500, {"ok": False, "error": str(exc)})

        self._httpd = _StudioHTTPServer((rt.host, rt.studio_port), StudioHandler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, name="studio-control-server", daemon=True)
        self._thread.start()

    def serve_forever(self) -> None:
        if self._httpd is None:
            self.start()
        assert self._thread is not None
        while self._thread.is_alive():
            self._thread.join(timeout=0.5)

    def stop(self) -> None:
        if self._httpd is not None:
            try:
                self._httpd.shutdown()
                self._httpd.server_close()
            except Exception:
                pass
            self._httpd = None
