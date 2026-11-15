"""Same-origin transparent reverse proxy (127.0.0.1:18766) and engine telemetry/probe client."""

from __future__ import annotations

import http.client
import http.server
import ipaddress
import json
import os
import re
import socketserver
import ssl
import threading
import time
import urllib.parse
from typing import Any

from .config_store import STUDIO_FAVICON_SVG, LogBroker

HOP_BY_HOP_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "proxy-connection",
    }
)

CSP_FRAME_ANCESTORS_RE = re.compile(r"frame-ancestors\s+[^;]*(?:;|$)", re.IGNORECASE)


def _is_loopback_or_private(host: str) -> bool:
    h = (host or "").strip().lower()
    if not h or h in ("localhost", "127.0.0.1", "::1"):
        return True
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_loopback or ip.is_private or ip.is_link_local
    except ValueError:
        return False


def _get_proxy_for_scheme(scheme: str) -> tuple[str, int] | None:
    """Resolve HTTP(S) proxy host/port from environment when targeting external hosts."""
    keys = (
        ("https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY")
        if scheme == "https"
        else ("http_proxy", "HTTP_PROXY")
    )
    raw = ""
    for k in keys:
        v = os.environ.get(k, "").strip()
        if v:
            raw = v
            break
    if not raw:
        return None
    if "://" not in raw:
        raw = "http://" + raw
    parsed = urllib.parse.urlparse(raw)
    if not parsed.hostname or not parsed.port:
        return None
    if parsed.scheme not in ("http", "https"):
        return None
    return parsed.hostname, parsed.port


def _open_upstream_connection(
    parsed_url: urllib.parse.ParseResult,
    *,
    connect_timeout: float = 10.0,
    read_timeout: float = 300.0,
) -> http.client.HTTPConnection:
    """Create an HTTP(S) connection to the parsed upstream, using system proxy tunnel if configured."""
    scheme = (parsed_url.scheme or "http").lower()
    host = parsed_url.hostname or "127.0.0.1"
    port = parsed_url.port or (443 if scheme == "https" else 80)

    proxy_hp = None if _is_loopback_or_private(host) else _get_proxy_for_scheme(scheme)

    if scheme == "https":
        ssl_ctx = ssl.create_default_context()
        if proxy_hp is not None:
            conn = http.client.HTTPSConnection(proxy_hp[0], proxy_hp[1], timeout=connect_timeout, context=ssl_ctx)
            conn.set_tunnel(host, port)
        else:
            conn = http.client.HTTPSConnection(host, port, timeout=connect_timeout, context=ssl_ctx)
    else:
        if proxy_hp is not None:
            conn = http.client.HTTPConnection(proxy_hp[0], proxy_hp[1], timeout=connect_timeout)
            conn.set_tunnel(host, port)
        else:
            conn = http.client.HTTPConnection(host, port, timeout=connect_timeout)

    conn.connect()
    if conn.sock is not None:
        conn.sock.settimeout(read_timeout)
    conn.timeout = read_timeout
    return conn


def _sanitize_csp(value: str) -> str:
    """Strip frame-ancestors directives so the Studio iframe can embed the UI cleanly."""
    cleaned = CSP_FRAME_ANCESTORS_RE.sub("", value or "").strip()
    cleaned = re.sub(r";\s*;", ";", cleaned).strip(" ;")
    return cleaned


def _rewrite_referer(referer: str, target_origin: str) -> str:
    """Rewrite Referer scheme + host to match the upstream origin while keeping path/query."""
    try:
        rp = urllib.parse.urlparse(referer)
        suffix = rp.path or "/"
        if rp.query:
            suffix = f"{suffix}?{rp.query}"
        return f"{target_origin}{suffix}"
    except Exception:
        return f"{target_origin}/"


def _standby_html(studio_port: int, proxy_port: int) -> bytes:
    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Maya · Strata Gateway Standby</title>
  <style>
    :root {{ color-scheme: dark; }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px;
      background: radial-gradient(circle at top, #131d31 0%, #0b0f17 60%);
      color: #e2e8f0;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
    }}
    .card {{
      width: min(560px, 100%);
      background: #111826;
      border: 1px solid rgba(148, 163, 184, 0.16);
      border-radius: 14px;
      padding: 28px 30px;
      box-shadow: 0 24px 60px rgba(0, 0, 0, 0.45);
    }}
    .pill {{
      display: inline-flex; align-items: center; gap: 8px;
      padding: 5px 11px; border-radius: 999px; font-size: 12px; font-weight: 600;
      background: rgba(245, 158, 11, 0.14); color: #fbbf24;
      border: 1px solid rgba(245, 158, 11, 0.28);
    }}
    .dot {{ width: 7px; height: 7px; border-radius: 50%; background: #f59e0b; }}
    h1 {{ margin: 14px 0 8px; font-size: 20px; font-weight: 650; letter-spacing: -0.01em; }}
    p {{ margin: 0 0 14px; color: #94a3b8; font-size: 14px; line-height: 1.6; }}
    code {{
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
      font-size: 12.5px; color: #cbd5e1;
      background: rgba(15, 23, 42, 0.85);
      border: 1px solid rgba(148, 163, 184, 0.14);
      padding: 2px 6px; border-radius: 5px;
    }}
    .steps {{
      margin: 16px 0 0; padding: 14px 16px; border-radius: 10px;
      background: rgba(15, 23, 42, 0.6);
      border: 1px solid rgba(148, 163, 184, 0.12);
      font-size: 13px; color: #cbd5e1; line-height: 1.75;
    }}
  </style>
</head>
<body>
  <main class="card">
    <div class="pill"><span class="dot"></span>同源透明代理待机 · Port {proxy_port}</div>
    <h1>尚未绑定上游推理节点</h1>
    <p>本机反向代理网关 <code>http://127.0.0.1:{proxy_port}</code> 已就绪。请在左侧控制面板完成以下任一操作，页面将自动切换为原生 WebUI：</p>
    <div class="steps">
      <div>1. 若已有运行中的 Colab 实例：点击 <strong>「🔗 无损纳管已运行会话」</strong>（只读探测并自动绑定隧道）。</div>
      <div>2. 若需新建实例：选择 GPU 与加速模式后点击 <strong>「⚡ 唤醒实例并部署」</strong>。</div>
      <div>3. 若接入远端或局域网 Strata 节点：切换至 <strong>Strata Engine</strong> 并填入节点地址挂载。</div>
    </div>
    <p style="margin-top: 16px; margin-bottom: 0; font-size: 12px; color: #64748b;">
      控制面板地址：<code>http://127.0.0.1:{studio_port}</code>
    </p>
  </main>
</body>
</html>
"""
    return html.encode("utf-8")


def _bad_gateway_html(err_msg: str) -> bytes:
    safe_msg = (
        err_msg.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )
    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <title>Upstream Unreachable</title>
  <style>
    body {{ margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0b0f17; color: #e2e8f0;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; padding: 24px; }}
    .box {{ max-width: 520px; background: #111826; border: 1px solid rgba(239,68,68,.3); border-radius: 12px; padding: 22px 24px; }}
    h2 {{ margin: 0 0 8px; font-size: 17px; color: #fca5a5; }}
    p {{ margin: 0; font-size: 13px; color: #94a3b8; line-height: 1.6; word-break: break-word; }}
  </style>
</head>
<body>
  <div class="box">
    <h2>上游推理引擎暂时不可达 (502)</h2>
    <p>{safe_msg}</p>
  </div>
</body>
</html>
"""
    return html.encode("utf-8")


class ProxyState:
    """Thread-safe upstream target configuration for the reverse proxy and telemetry client."""

    def __init__(self, studio_port: int, proxy_port: int) -> None:
        self._lock = threading.RLock()
        self.studio_port = studio_port
        self.proxy_port = proxy_port
        self.upstream_url: str = ""
        self.engine_kind: str = "maya"
        self.api_key: str = ""
        self.last_error: str = ""
        self.last_status_code: int | None = None

    def set_upstream(
        self,
        upstream_url: str,
        *,
        engine_kind: str | None = None,
        api_key: str | None = None,
    ) -> None:
        with self._lock:
            self.upstream_url = (upstream_url or "").strip().rstrip("/")
            if engine_kind in ("maya", "strata"):
                self.engine_kind = engine_kind
            if api_key is not None:
                self.api_key = api_key.strip()
            self.last_error = ""

    def snapshot(self) -> tuple[str, str, str]:
        with self._lock:
            return self.upstream_url, self.engine_kind, self.api_key

    def record_status(self, status_code: int | None, error: str = "") -> None:
        with self._lock:
            self.last_status_code = status_code
            self.last_error = error


class _ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        host, port = self.socket.getsockname()[:2]
        self.server_name = str(host)
        self.server_port = int(port)


class EngineProxyServer:
    """Runs the same-origin transparent HTTP/SSE reverse proxy on 127.0.0.1:<proxy_port>."""

    def __init__(
        self,
        host: str,
        proxy_port: int,
        studio_port: int,
        logs: LogBroker,
        *,
        initial_upstream: str = "",
        initial_kind: str = "maya",
        initial_api_key: str = "",
    ) -> None:
        self.host = host
        self.proxy_port = proxy_port
        self.studio_port = studio_port
        self.logs = logs
        self.state = ProxyState(studio_port=studio_port, proxy_port=proxy_port)
        if initial_upstream:
            self.state.set_upstream(
                initial_upstream,
                engine_kind=initial_kind,
                api_key=initial_api_key,
            )
        self._httpd: _ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def set_upstream(
        self,
        upstream_url: str,
        *,
        engine_kind: str | None = None,
        api_key: str | None = None,
    ) -> None:
        self.state.set_upstream(upstream_url, engine_kind=engine_kind, api_key=api_key)

    def start(self) -> None:
        if self._httpd is not None:
            return
        proxy_state = self.state
        studio_port = self.studio_port
        proxy_port = self.proxy_port

        class ProxyHandler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
                return

            def _send_cors_headers(self) -> None:
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
                self.send_header(
                    "Access-Control-Allow-Headers",
                    "Content-Type, Authorization, x-api-key, anthropic-version",
                )
                self.send_header("Access-Control-Max-Age", "600")

            def _read_request_body(self) -> bytes:
                cl = self.headers.get("Content-Length")
                if cl is not None:
                    try:
                        n = max(0, int(cl))
                    except ValueError:
                        n = 0
                    return self.rfile.read(n) if n > 0 else b""
                te = (self.headers.get("Transfer-Encoding") or "").lower()
                if "chunked" in te:
                    chunks: list[bytes] = []
                    while True:
                        line = self.rfile.readline(65536)
                        if not line:
                            break
                        size_str = line.split(b";", 1)[0].strip()
                        try:
                            sz = int(size_str, 16)
                        except ValueError:
                            break
                        if sz == 0:
                            while True:
                                trailer = self.rfile.readline(65536)
                                if not trailer or trailer in (b"\r\n", b"\n"):
                                    break
                            break
                        chunks.append(self.rfile.read(sz))
                        self.rfile.read(2)  # CRLF
                    return b"".join(chunks)
                return b""

            def _send_json(self, status: int, payload: dict[str, Any], *, is_v1: bool = False) -> None:
                raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Cache-Control", "no-store")
                if is_v1:
                    self._send_cors_headers()
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(raw)

            def _send_favicon_svg(self) -> None:
                self.send_response(200)
                self.send_header("Content-Type", "image/svg+xml; charset=utf-8")
                self.send_header("Content-Length", str(len(STUDIO_FAVICON_SVG)))
                self.send_header("Cache-Control", "public, max-age=86400")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(STUDIO_FAVICON_SVG)

            def _handle_unconfigured(self, path_only: str) -> None:
                is_v1 = path_only.startswith("/v1/")
                if self.command == "OPTIONS" and is_v1:
                    self.send_response(204)
                    self._send_cors_headers()
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.command in ("GET", "HEAD") and path_only == "/favicon.ico":
                    self._send_favicon_svg()
                    return
                if self.command in ("GET", "HEAD") and path_only in ("/", "/index.html"):
                    body = _standby_html(studio_port, proxy_port)
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    if self.command != "HEAD":
                        self.wfile.write(body)
                    return
                self._send_json(
                    503,
                    {
                        "ok": False,
                        "error": {
                            "type": "upstream_unconfigured",
                            "message": "Upstream engine is not configured yet. Attach or deploy via Studio.",
                        },
                    },
                    is_v1=is_v1,
                )

            def _proxy(self) -> None:
                path_only = self.path.split("?", 1)[0]
                is_v1 = path_only.startswith("/v1/")
                upstream_url, _, api_key = proxy_state.snapshot()
                if not upstream_url:
                    self._handle_unconfigured(path_only)
                    return

                parsed = urllib.parse.urlparse(upstream_url)
                scheme = (parsed.scheme or "http").lower()
                netloc = parsed.netloc
                if not netloc:
                    self._handle_unconfigured(path_only)
                    return

                base_path = parsed.path.rstrip("/")
                target_path = f"{base_path}{self.path}" if base_path else self.path
                if not target_path.startswith("/"):
                    target_path = "/" + target_path
                target_origin = f"{scheme}://{netloc}"

                req_body = self._read_request_body()

                out_headers: dict[str, str] = {}
                has_auth = False
                has_origin = False
                has_referer = False
                for key, val in self.headers.items():
                    kl = key.lower()
                    if kl in HOP_BY_HOP_HEADERS or kl in ("host", "accept-encoding", "content-length"):
                        continue
                    if kl in ("authorization", "x-api-key"):
                        has_auth = True
                    if kl == "origin":
                        has_origin = True
                        out_headers["Origin"] = target_origin
                        continue
                    if kl == "referer":
                        has_referer = True
                        out_headers["Referer"] = _rewrite_referer(val, target_origin)
                        continue
                    out_headers[key] = val

                out_headers["Host"] = netloc
                out_headers["Accept-Encoding"] = "identity"
                if req_body or self.command in ("POST", "PUT", "PATCH"):
                    out_headers["Content-Length"] = str(len(req_body))
                if api_key and not has_auth:
                    out_headers["Authorization"] = f"Bearer {api_key}"
                if not has_origin and self.headers.get("Origin"):
                    out_headers["Origin"] = target_origin
                if not has_referer and self.headers.get("Referer"):
                    out_headers["Referer"] = _rewrite_referer(self.headers["Referer"], target_origin)

                conn: http.client.HTTPConnection | None = None
                try:
                    conn = _open_upstream_connection(parsed, connect_timeout=10.0, read_timeout=300.0)
                    conn.request(self.command, target_path, body=req_body if req_body else None, headers=out_headers)
                    resp = conn.getresponse()
                except Exception as exc:
                    if conn is not None:
                        try:
                            conn.close()
                        except Exception:
                            pass
                    proxy_state.record_status(502, str(exc))
                    if self.command == "OPTIONS" and is_v1:
                        self.send_response(204)
                        self._send_cors_headers()
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    accept = (self.headers.get("Accept") or "").lower()
                    if self.command == "GET" and path_only in ("/", "/index.html") and "text/html" in accept:
                        body = _bad_gateway_html(str(exc))
                        self.send_response(502)
                        self.send_header("Content-Type", "text/html; charset=utf-8")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                        return
                    self._send_json(
                        502,
                        {"ok": False, "error": {"type": "upstream_unreachable", "message": str(exc)}},
                        is_v1=is_v1,
                    )
                    return

                try:
                    proxy_state.record_status(resp.status, "")

                    # Handle CORS preflight transparently for /v1/* even if upstream restricts cors_origins
                    if self.command == "OPTIONS" and is_v1 and resp.status in (403, 404, 405, 501):
                        resp.read()
                        self.send_response(204)
                        self._send_cors_headers()
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return

                    if self.command in ("GET", "HEAD") and path_only == "/favicon.ico" and resp.status == 404:
                        resp.read()
                        self._send_favicon_svg()
                        return

                    raw_headers = resp.getheaders()
                    resp_ct = ""
                    resp_cl = None
                    is_chunked = False
                    for hk, hv in raw_headers:
                        hkl = hk.lower()
                        if hkl == "content-type":
                            resp_ct = hv.lower()
                        elif hkl == "content-length":
                            try:
                                resp_cl = int(hv)
                            except ValueError:
                                resp_cl = None
                        elif hkl == "transfer-encoding" and "chunked" in hv.lower():
                            is_chunked = True

                    is_stream = (
                        "text/event-stream" in resp_ct
                        or is_chunked
                        or (resp_cl is None and self.command != "HEAD")
                    )

                    self.send_response(resp.status, resp.reason)
                    has_acao = False
                    for hk, hv in raw_headers:
                        hkl = hk.lower()
                        if hkl in HOP_BY_HOP_HEADERS:
                            continue
                        if hkl == "x-frame-options":
                            continue
                        if hkl == "content-security-policy":
                            if "frame-ancestors" in hv.lower():
                                cleaned = _sanitize_csp(hv)
                                if cleaned:
                                    self.send_header(hk, cleaned)
                            else:
                                self.send_header(hk, hv)
                            continue
                        if hkl == "content-length" and is_stream:
                            continue
                        if hkl == "location":
                            if hv.startswith(target_origin):
                                rel_loc = hv[len(target_origin):] or "/"
                                self.send_header(hk, rel_loc)
                            else:
                                self.send_header(hk, hv)
                            continue
                        if hkl == "access-control-allow-origin":
                            has_acao = True
                        self.send_header(hk, hv)

                    if is_v1 and not has_acao:
                        self._send_cors_headers()

                    if is_stream:
                        self.send_header("Connection", "close")
                        self.close_connection = True

                    self.end_headers()

                    if self.command == "HEAD":
                        return

                    if is_stream:
                        while True:
                            chunk = resp.read1(4096) if hasattr(resp, "read1") else resp.read(4096)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            self.wfile.flush()
                    elif resp_cl is not None:
                        rem = resp_cl
                        while rem > 0:
                            chunk = resp.read(min(65536, rem))
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            rem -= len(chunk)
                        self.wfile.flush()
                    else:
                        data = resp.read()
                        if data:
                            self.wfile.write(data)
                            self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    self.close_connection = True
                finally:
                    try:
                        conn.close()
                    except Exception:
                        pass

            def do_GET(self) -> None:
                self._proxy()

            def do_POST(self) -> None:
                self._proxy()

            def do_PUT(self) -> None:
                self._proxy()

            def do_DELETE(self) -> None:
                self._proxy()

            def do_PATCH(self) -> None:
                self._proxy()

            def do_OPTIONS(self) -> None:
                self._proxy()

            def do_HEAD(self) -> None:
                self._proxy()

        self._httpd = _ThreadingHTTPServer((self.host, self.proxy_port), ProxyHandler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, name="studio-engine-proxy", daemon=True)
        self._thread.start()
        self.logs.emit("proxy", "info", f"同源透明反向代理已监听 http://{self.host}:{self.proxy_port}")

    def stop(self) -> None:
        if self._httpd is not None:
            try:
                self._httpd.shutdown()
                self._httpd.server_close()
            except Exception:
                pass
            self._httpd = None


def _fetch_upstream(
    upstream_url: str,
    path: str,
    *,
    api_key: str = "",
    method: str = "GET",
    body: bytes | None = None,
    timeout: float = 2.5,
) -> tuple[int, dict[str, str], bytes]:
    """Perform a single HTTP(S) call to the upstream engine honoring system proxy rules."""
    parsed = urllib.parse.urlparse(upstream_url.rstrip("/"))
    scheme = (parsed.scheme or "http").lower()
    netloc = parsed.netloc
    base_path = parsed.path.rstrip("/")
    target_path = f"{base_path}{path}" if base_path else path
    headers = {
        "Host": netloc,
        "Accept": "application/json, text/plain;q=0.9, */*;q=0.8",
        "Accept-Encoding": "identity",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(body))
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    conn = _open_upstream_connection(parsed, connect_timeout=min(timeout, 5.0), read_timeout=timeout)
    try:
        conn.request(method, target_path, body=body, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        hdrs = {k.lower(): v for k, v in resp.getheaders()}
        return resp.status, hdrs, raw
    finally:
        try:
            conn.close()
        except Exception:
            pass


def _parse_json_safe(raw: bytes) -> dict[str, Any] | list[Any] | None:
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return None


def _to_float(val: Any) -> float | None:
    if val is None or isinstance(val, bool):
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def _normalize_hit_pct(val: Any) -> float | None:
    f = _to_float(val)
    if f is None:
        return None
    if 0.0 <= f <= 1.0:
        return round(f * 100.0, 1)
    return round(f, 1)


def _parse_prometheus_metrics(text: str) -> dict[str, float]:
    out: dict[str, float] = {}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split()
        if len(parts) < 2:
            continue
        metric_name = parts[0].split("{", 1)[0]
        val = _to_float(parts[-1])
        if val is not None:
            out[metric_name] = val
    return out


def fetch_engine_telemetry(
    upstream_url: str,
    engine_kind: str = "maya",
    api_key: str = "",
    strata_model: str = "",
    timeout: float = 2.5,
) -> dict[str, Any]:
    """Poll /health, /metrics, /status, /v1/models and normalize Maya or Strata telemetry."""
    empty: dict[str, Any] = {
        "online": False,
        "loaded": False,
        "model_id": strata_model if engine_kind == "strata" and strata_model else "",
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
    if not upstream_url:
        return empty

    online = False
    loaded = False
    model_id = strata_model if engine_kind == "strata" and strata_model else ""
    requests_total: int | None = None
    last_prefill_tok_s: float | None = None
    last_decode_tok_s: float | None = None
    vram_hit_pct: float | None = None
    busy = False
    queued = 0
    recent_requests: list[dict[str, Any]] = []

    health_data: dict[str, Any] | None = None
    try:
        st, _, raw = _fetch_upstream(upstream_url, "/health", api_key=api_key, timeout=timeout)
        if st == 200:
            online = True
            parsed = _parse_json_safe(raw)
            if isinstance(parsed, dict):
                health_data = parsed
    except Exception:
        pass

    status_data: dict[str, Any] | None = None
    if engine_kind == "strata" or health_data is None:
        try:
            st, _, raw = _fetch_upstream(upstream_url, "/status", api_key=api_key, timeout=timeout)
            if st == 200:
                online = True
                parsed = _parse_json_safe(raw)
                if isinstance(parsed, dict):
                    status_data = parsed
        except Exception:
            pass

    metrics_json: dict[str, Any] | None = None
    metrics_prom: dict[str, float] = {}
    try:
        st, _, raw = _fetch_upstream(upstream_url, "/metrics", api_key=api_key, timeout=timeout)
        if st == 200:
            online = True
            parsed = _parse_json_safe(raw)
            if isinstance(parsed, dict):
                metrics_json = parsed
            else:
                metrics_prom = _parse_prometheus_metrics(raw.decode("utf-8", "replace"))
    except Exception:
        pass

    models_data: dict[str, Any] | None = None
    try:
        st, _, raw = _fetch_upstream(upstream_url, "/v1/models", api_key=api_key, timeout=timeout)
        if st == 200:
            online = True
            parsed = _parse_json_safe(raw)
            if isinstance(parsed, dict):
                models_data = parsed
    except Exception:
        pass

    if not online:
        return empty

    # Resolve loaded status
    if health_data is not None:
        h_status = str(health_data.get("status") or "").lower()
        unloaded = bool(health_data.get("unloaded", False))
        if isinstance(health_data.get("loaded"), bool):
            loaded = bool(health_data["loaded"]) and not unloaded
        elif h_status in ("ok", "ready", "healthy", "loaded"):
            loaded = not unloaded
        elif h_status in ("loading", "reloading", "updating", "unloaded"):
            loaded = False
        else:
            loaded = not unloaded
        if health_data.get("model"):
            model_id = str(health_data["model"])
    elif status_data is not None:
        s_status = str(status_data.get("status") or "").lower()
        if isinstance(status_data.get("loaded"), bool):
            loaded = bool(status_data["loaded"])
        else:
            loaded = s_status in ("ok", "ready", "healthy", "loaded", "idle", "busy", "generating")
    else:
        loaded = models_data is not None

    # Resolve model_id from /metrics or /v1/models
    if metrics_json and isinstance(metrics_json.get("engine"), dict):
        eng_model = metrics_json["engine"].get("model")
        if eng_model:
            model_id = str(eng_model)
    if status_data:
        for k in ("model_id", "model"):
            if status_data.get(k):
                model_id = str(status_data[k])
                break
    if not model_id and models_data and isinstance(models_data.get("data"), list) and models_data["data"]:
        first_m = models_data["data"][0]
        if isinstance(first_m, dict) and first_m.get("id"):
            model_id = str(first_m["id"])

    # Parse Maya / Strata JSON /metrics
    if metrics_json:
        totals = metrics_json.get("totals")
        if isinstance(totals, dict) and totals.get("requests") is not None:
            try:
                requests_total = int(totals["requests"])
            except (TypeError, ValueError):
                pass
        elif metrics_json.get("requests_total") is not None:
            try:
                requests_total = int(metrics_json["requests_total"])
            except (TypeError, ValueError):
                pass

        live = metrics_json.get("live")
        if isinstance(live, dict):
            lstate = str(live.get("state") or "").lower()
            busy = lstate in ("reading", "generating") or int(live.get("active") or 0) > 0
            queued = int(live.get("queued") or 0)
            if live.get("prefill_tok_s_mean") is not None:
                last_prefill_tok_s = round(float(live["prefill_tok_s_mean"]), 1)
            if live.get("tok_s") is not None:
                last_decode_tok_s = round(float(live["tok_s"]), 1)
            elif live.get("tok_s_mean") is not None:
                last_decode_tok_s = round(float(live["tok_s_mean"]), 1)

        tiers = metrics_json.get("tiers")
        if isinstance(tiers, dict) and isinstance(tiers.get("now"), dict):
            now_tiers = tiers["now"]
            vram_hit_pct = _normalize_hit_pct(now_tiers.get("vram_hit"))

        raw_reqs = metrics_json.get("requests") or metrics_json.get("recent_requests")
        if isinstance(raw_reqs, list):
            for row in raw_reqs[:12]:
                if not isinstance(row, dict):
                    continue
                ptok = row.get("prompt_tokens")
                reused = row.get("reused") or 0
                pms = _to_float(row.get("prompt_ms"))
                pf_tok_s = _to_float(row.get("prefill_tok_s"))
                if pf_tok_s is None and ptok is not None and pms and pms > 0:
                    eff_tokens = max(0, int(ptok) - int(reused))
                    if eff_tokens == 0:
                        eff_tokens = int(ptok)
                    if eff_tokens > 0:
                        pf_tok_s = round(eff_tokens / (pms / 1000.0), 1)
                dec_tok_s = _to_float(row.get("decode_tok_s"))
                hit_pct = _normalize_hit_pct(row.get("hit_rate") if "hit_rate" in row else row.get("vram_hit_pct"))
                recent_requests.append(
                    {
                        "time": row.get("time"),
                        "duration_s": _to_float(row.get("duration_s")),
                        "prompt_tokens": ptok,
                        "reused": reused,
                        "output_tokens": row.get("output_tokens"),
                        "prompt_ms": pms,
                        "decode_ms": _to_float(row.get("decode_ms")),
                        "prefill_tok_s": round(pf_tok_s, 1) if pf_tok_s is not None else None,
                        "decode_tok_s": round(dec_tok_s, 1) if dec_tok_s is not None else None,
                        "hit_rate_pct": hit_pct,
                        "drafts_accepted": row.get("drafts_accepted"),
                        "drafts_offered": row.get("drafts_offered"),
                    }
                )
            if recent_requests:
                newest = recent_requests[0]
                if last_decode_tok_s is None and newest.get("decode_tok_s") is not None:
                    last_decode_tok_s = newest["decode_tok_s"]
                if last_prefill_tok_s is None and newest.get("prefill_tok_s") is not None:
                    last_prefill_tok_s = newest["prefill_tok_s"]
                if vram_hit_pct is None and newest.get("hit_rate_pct") is not None:
                    vram_hit_pct = newest["hit_rate_pct"]

        # Direct top-level telemetry fields (e.g. Strata JSON /metrics)
        if last_prefill_tok_s is None:
            for k in ("last_prefill_tok_s", "prefill_tok_s"):
                v = _to_float(metrics_json.get(k))
                if v is not None:
                    last_prefill_tok_s = round(v, 1)
                    break
        if last_decode_tok_s is None:
            for k in ("last_decode_tok_s", "decode_tok_s", "tok_s"):
                v = _to_float(metrics_json.get(k))
                if v is not None:
                    last_decode_tok_s = round(v, 1)
                    break
        if vram_hit_pct is None:
            for k in ("vram_hit_pct", "vram_hit"):
                if metrics_json.get(k) is not None:
                    vram_hit_pct = _normalize_hit_pct(metrics_json.get(k))
                    break

    # Overlay Strata /status fields if present
    if status_data:
        if requests_total is None and status_data.get("requests_total") is not None:
            try:
                requests_total = int(status_data["requests_total"])
            except (TypeError, ValueError):
                pass
        if last_prefill_tok_s is None:
            for k in ("last_prefill_tok_s", "prefill_tok_s"):
                v = _to_float(status_data.get(k))
                if v is not None:
                    last_prefill_tok_s = round(v, 1)
                    break
        if last_decode_tok_s is None:
            for k in ("last_decode_tok_s", "decode_tok_s", "tok_s"):
                v = _to_float(status_data.get(k))
                if v is not None:
                    last_decode_tok_s = round(v, 1)
                    break
        if vram_hit_pct is None:
            for k in ("vram_hit_pct", "vram_hit"):
                if status_data.get(k) is not None:
                    vram_hit_pct = _normalize_hit_pct(status_data.get(k))
                    break
        if "busy" in status_data:
            busy = bool(status_data["busy"])
        if status_data.get("queued") is not None:
            try:
                queued = int(status_data["queued"])
            except (TypeError, ValueError):
                pass
        if not recent_requests and isinstance(status_data.get("recent_requests"), list):
            recent_requests = [r for r in status_data["recent_requests"][:12] if isinstance(r, dict)]

    # Overlay Prometheus metrics if present
    if metrics_prom:
        if requests_total is None:
            for k in ("strata_requests_total", "maya_requests_total", "requests_total"):
                if k in metrics_prom:
                    requests_total = int(metrics_prom[k])
                    break
        if last_prefill_tok_s is None:
            for k in ("strata_prefill_tok_s", "maya_prefill_tok_s", "prefill_tok_s"):
                if k in metrics_prom:
                    last_prefill_tok_s = round(metrics_prom[k], 1)
                    break
        if last_decode_tok_s is None:
            for k in ("strata_decode_tok_s", "maya_decode_tok_s", "decode_tok_s"):
                if k in metrics_prom:
                    last_decode_tok_s = round(metrics_prom[k], 1)
                    break
        if vram_hit_pct is None:
            for k in ("strata_vram_hit_pct", "maya_vram_hit_ratio", "vram_hit_pct"):
                if k in metrics_prom:
                    vram_hit_pct = _normalize_hit_pct(metrics_prom[k])
                    break

    return {
        "online": online,
        "loaded": loaded,
        "model_id": model_id,
        "telemetry": {
            "requests_total": requests_total,
            "last_prefill_tok_s": last_prefill_tok_s,
            "last_decode_tok_s": last_decode_tok_s,
            "vram_hit_pct": vram_hit_pct,
            "busy": busy,
            "queued": queued,
            "recent_requests": recent_requests,
        },
    }


def send_chat_probe(
    *,
    proxy_port: int,
    prompt: str,
    max_tokens: int = 128,
    model_id: str = "",
    api_key: str = "",
    timeout: float = 120.0,
) -> dict[str, Any]:
    """Run a non-streaming /v1/chat/completions probe via the local reverse proxy."""
    chosen_model = (model_id or "").strip()
    if not chosen_model:
        try:
            st, _, raw = _fetch_upstream(f"http://127.0.0.1:{proxy_port}", "/v1/models", api_key=api_key, timeout=4.0)
            if st == 200:
                parsed = _parse_json_safe(raw)
                if isinstance(parsed, dict) and parsed.get("data"):
                    chosen_model = str(parsed["data"][0].get("id") or "")
        except Exception:
            pass
    if not chosen_model:
        chosen_model = "deepseek-v4.1-flash-abliterated"

    payload = {
        "model": chosen_model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max(1, min(8192, int(max_tokens))),
        "stream": False,
    }
    body = json.dumps(payload).encode("utf-8")
    t0 = time.perf_counter()
    try:
        st, _, raw = _fetch_upstream(
            f"http://127.0.0.1:{proxy_port}",
            "/v1/chat/completions",
            api_key=api_key,
            method="POST",
            body=body,
            timeout=timeout,
        )
        elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 1)
    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 1)
        return {
            "ok": False,
            "status_code": 502,
            "model": chosen_model,
            "reply": "",
            "reasoning": "",
            "usage": {},
            "elapsed_ms": elapsed_ms,
            "tok_s": None,
            "error": str(exc),
        }

    parsed = _parse_json_safe(raw)
    if st != 200 or not isinstance(parsed, dict):
        err_text = raw.decode("utf-8", "replace")[:500]
        if isinstance(parsed, dict) and isinstance(parsed.get("error"), dict):
            err_text = str(parsed["error"].get("message") or err_text)
        return {
            "ok": False,
            "status_code": st,
            "model": chosen_model,
            "reply": "",
            "reasoning": "",
            "usage": {},
            "elapsed_ms": elapsed_ms,
            "tok_s": None,
            "error": err_text,
        }

    choices = parsed.get("choices") or []
    msg = choices[0].get("message", {}) if choices and isinstance(choices[0], dict) else {}
    reply = str(msg.get("content") or "")
    reasoning = str(msg.get("reasoning_content") or "")
    usage = parsed.get("usage") if isinstance(parsed.get("usage"), dict) else {}
    comp_tokens = usage.get("completion_tokens")
    tok_s = None
    if comp_tokens and elapsed_ms > 0:
        tok_s = round(float(comp_tokens) / (elapsed_ms / 1000.0), 1)
    return {
        "ok": True,
        "status_code": st,
        "model": str(parsed.get("model") or chosen_model),
        "reply": reply,
        "reasoning": reasoning,
        "usage": usage,
        "elapsed_ms": elapsed_ms,
        "tok_s": tok_s,
        "error": "",
    }
