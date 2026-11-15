#!/usr/bin/env python3
"""
Offline secret, PII, and tar-header hygiene auditor for the public colab-maya-ds4-256g repo.

Exits 0 if clean, non-zero if any credential file, token, private key, live tunnel domain,
personal macOS user path, or non-root tar metadata is found.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FORBIDDEN_FILENAMES = {
    "gcs-key.json",
    "gcs-bucket",
    "hf-token",
    "maya-api-key",
    "strata-api-key",
    ".env",
}

FORBIDDEN_SUFFIXES = (".key", ".pem")

CHECKS: list[tuple[str, re.Pattern[bytes], set[bytes]]] = [
    (
        "HuggingFace token",
        re.compile(rb"hf_[A-Za-z0-9]{20,}"),
        {b"hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", b"hf_your_huggingface_token"},
    ),
    (
        "Private key block",
        re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        set(),
    ),
    (
        "Google OAuth access token",
        re.compile(rb"ya29\.[A-Za-z0-9_-]{20,}"),
        set(),
    ),
    (
        "Google API key",
        re.compile(rb"AIza[0-9A-Za-z_-]{35}"),
        set(),
    ),
    (
        "GCP service account email",
        re.compile(rb"[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+\.iam\.gserviceaccount\.com"),
        {b"maya-reader@your-gcp-project-id.iam.gserviceaccount.com"},
    ),
    (
        "Cloudflare Tunnel subdomain",
        re.compile(rb"[a-zA-Z0-9-]+\.trycloudflare\.com"),
        {b"a-zA-Z0-9-"},
    ),
    (
        "Personal macOS home path",
        re.compile(rb"/Users/[A-Za-z0-9_-]+"),
        {b"/Users/<name>", b"/Users/<username>"},
    ),
    (
        "Colab internal VM ID",
        re.compile(rb"gpu-(?:g4|a100|h100)-[a-z0-9-]+-[a-z0-9]{6,}"),
        set(),
    ),
]

JUNK_NAMES = {".DS_Store", "__MACOSX"}


def is_junk(name: str) -> bool:
    parts = Path(name).parts
    return any(p in JUNK_NAMES or p.startswith("._") for p in parts)


def line_allows_match(data: bytes, start: int, end: int, name: str, allowlist: set[bytes]) -> bool:
    matched = data[start:end]
    if matched in allowlist:
        return True
    line_s = data.rfind(b"\n", 0, start) + 1
    line_e = data.find(b"\n", end)
    if line_e == -1:
        line_e = len(data)
    line = data[line_s:line_e]
    if name == "Private key block" and b"YOUR_PRIVATE_KEY_HERE" in data[start : start + 120]:
        return True
    if name == "Cloudflare Tunnel subdomain":
        if b"<example" in line or b"<random" in line or b"\\." in line or b"re.compile" in line:
            return True
    return False


def scan_bytes(label: str, data: bytes, findings: list[str]) -> None:
    if label == "scripts/audit_secrets.py":
        return
    for name, rx, allowlist in CHECKS:
        for m in rx.finditer(data):
            if not line_allows_match(data, m.start(), m.end(), name, allowlist):
                findings.append(f"[{name}] found in {label}")
                break


def gather_repo_files() -> list[Path]:
    if (ROOT / ".git").is_dir():
        tracked = subprocess.check_output(
            ["git", "-C", str(ROOT), "ls-files", "-z"], stderr=subprocess.DEVNULL
        ).split(b"\x00")
        untracked = subprocess.check_output(
            ["git", "-C", str(ROOT), "ls-files", "--others", "--exclude-standard", "-z"],
            stderr=subprocess.DEVNULL,
        ).split(b"\x00")
        rels = {p.decode("utf-8") for p in tracked + untracked if p}
        return sorted(ROOT / r for r in rels if (ROOT / r).is_file())

    out: list[Path] = []
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d != ".git"]
        for fn in fns:
            p = Path(dp) / fn
            out.append(p)
    return sorted(out)


def audit_tar_gz(path: Path, rel: str, findings: list[str]) -> tuple[int, int]:
    entries = 0
    non_root = 0
    with tarfile.open(path, "r:gz") as tf:
        for m in tf.getmembers():
            entries += 1
            if is_junk(m.name):
                findings.append(f"[macOS junk in tar] {rel} -> {m.name}")
            if m.uid != 0 or m.gid != 0 or m.uname != "root" or m.gname != "root":
                non_root += 1
            if m.isfile():
                fobj = tf.extractfile(m)
                if fobj is not None:
                    scan_bytes(f"{rel}:{m.name}", fobj.read(), findings)
    if non_root > 0:
        findings.append(f"[Non-root tar headers] {rel}: {non_root} entries not root:root (0:0)")
    return entries, non_root


def main() -> int:
    findings: list[str] = []
    files = gather_repo_files()
    tar_summary: list[str] = []

    for p in files:
        rel = p.relative_to(ROOT).as_posix()
        base = p.name
        if is_junk(rel):
            findings.append(f"[macOS junk file] {rel}")
        if (base in FORBIDDEN_FILENAMES or base.endswith(FORBIDDEN_SUFFIXES)) and not base.endswith(".example"):
            findings.append(f"[Forbidden credential filename] {rel}")
        if rel.endswith(".tar.gz"):
            cnt, nr = audit_tar_gz(p, rel, findings)
            tar_summary.append(f"{rel} ({cnt} entries, non_root={nr})")
        else:
            scan_bytes(rel, p.read_bytes(), findings)

    if (ROOT / ".git").is_dir():
        try:
            log_out = subprocess.check_output(
                ["git", "-C", str(ROOT), "log", "--format=%an|%ae|%cn|%ce"],
                stderr=subprocess.DEVNULL,
            ).decode("utf-8", "ignore")
            for ln in log_out.splitlines():
                if not ln.strip():
                    continue
                if re.search(r"/Users/[A-Za-z0-9_-]+", ln):
                    findings.append(f"[Personal path in git commit metadata] {ln}")
        except subprocess.CalledProcessError:
            pass

    print(f"Scanned files: {len(files)}")
    for ts in tar_summary:
        print(f"Audited archive: {ts}")
    print(f"Findings count: {len(findings)}")
    for item in findings:
        print(f"  FAIL: {item}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
