"""CLI entry point for Maya · Strata Studio (`python3 -m studio`)."""

from __future__ import annotations

import argparse
import signal
import sys
import threading
import webbrowser

from . import __app_name__, __version__
from .server import StudioRuntime, StudioServer


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python3 -m studio",
        description=f"{__app_name__} v{__version__} — local control plane, Colab bridge & same-origin proxy.",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=18765, help="Studio control-plane HTTP port (default: 18765)")
    parser.add_argument("--proxy-port", type=int, default=18766, help="Same-origin reverse proxy port (default: 18766)")
    parser.add_argument(
        "--auto-attach",
        action="store_true",
        help="Automatically run read-only attach against an active Colab session at startup",
    )
    parser.add_argument(
        "--open-browser",
        action="store_true",
        help="Open the Studio WebUI in the default browser after startup",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    runtime = StudioRuntime(
        host=args.host,
        studio_port=args.port,
        proxy_port=args.proxy_port,
    )
    server = StudioServer(runtime)

    stop_once = threading.Event()

    def _shutdown_handler(_signum: int, _frame: object) -> None:
        stop_once.set()

    signal.signal(signal.SIGINT, _shutdown_handler)
    signal.signal(signal.SIGTERM, _shutdown_handler)

    runtime.start_background(auto_attach=args.auto_attach)
    server.start()

    print(
        f"[{__app_name__}] Control plane: http://{args.host}:{args.port} | "
        f"Proxy gateway: http://{args.host}:{args.proxy_port}",
        flush=True,
    )

    if args.open_browser:
        try:
            webbrowser.open(f"http://{args.host}:{args.port}")
        except Exception:
            pass

    try:
        while not stop_once.is_set():
            stop_once.wait(0.5)
    except KeyboardInterrupt:
        _shutdown_handler(signal.SIGINT, None)
    finally:
        server.stop()
        runtime.stop_background()
    return 0


if __name__ == "__main__":
    sys.exit(main())
