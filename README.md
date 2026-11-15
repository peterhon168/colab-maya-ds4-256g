# colab-maya-ds4-256g

Deploy **DeepSeek-V4.1-Flash-1017 (`Mix-256G` / `abliterated-256g`, 748B MoE)** on Google Colab **G4 (`NVIDIA RTX PRO 6000 Blackwell Server Edition 96GB`, `sm_120`)** or **A100 High-RAM (`80GB`, `sm_80`)** using [Project Maya (`maya-ds4` `v1.1.56`)](https://github.com/mw00/project-maya), complete with pre-built CUDA binaries, pre-packed metadata, dual-regime HTTP/2 GCS acceleration, Cloudflare Tunnel exposure, and 12-minute Jupyter kernel keepalive.

> **Security by design:** No real GCP service account keys, GCS bucket names, Hugging Face tokens, private tunnel URLs, or personal machine paths are included in this repository. Put your credentials in `~/.config/maya-gcs/` (outside Git) and run `python3 scripts/audit_secrets.py` before pushing any fork.

---

## Architecture Overview

`scripts/start_g4_256g.sh` automatically selects one of three storage & execution modes based on the attached Colab VM hardware and provided credentials:

```mermaid
flowchart LR
    VM["Colab VM Boot"] --> CHECK{"/mnt/local-scratch >= 200G?"}
    CHECK -- "Yes (A100 Dual-Disk)" --> MODEA["Mode A: Shards 1-3 on /mnt/local-scratch, 4-7 on /, 100% RAM/VRAM Experts"]
    CHECK -- "No (G4 236G Single-Disk)" --> HFCHK{"HF Token Available? (Default Zero-Boot-GCS)"}
    HFCHK -- "Yes (Zero-Egress B1)" --> MODEB1["Mode B1: Shards 1-4 NVMe (HF Xet $0) + Shards 5-7 /mnt/hf (hf_ro_fuse + HTTP/2 $0)"]
    HFCHK -- "No + GCS Creds" --> MODEGCS["Mode B1-GCS: Legacy /mnt/gcs gcsfuse Fallback"]
    HFCHK -- "No Creds" --> MODEB2["Mode B2: Remount /dev/shm 110G for Shard 2 + MAYA_DS4_DISK_SKIP_W=1.01"]
    MODEB1 --> TIER1["Shard 00002: mincore() OS Page Cache"]
    TIER1 -- "Cache Miss (tot <= 160)" --> NVME["100% Local NVMe (Zero Network RTT for Decode, $0)"]
    TIER1 -- "Prefill Burst (tot > 160, w/ GCS Key)" --> SPLIT["QD=16 Local NVMe + 752 Threads -> 8x8 HTTP/2 curl_multi (50Gbps GCS)"]
    MODEB1 --> COLD["/mnt/hf Reads > 256 KB & 2 MB Header Windows -> Direct HTTPS HTTP/2 Range (us.gcp.cdn.hf.co, $0/GB)"]
```

---

## Measured Hardware & Performance Summary

| Scenario | GPU & Host | Model & Storage Layout | Cold Load Time | Prefill Speed | Decode Speed (with `DSpark`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **G4 Mode B1 (Zero-Boot-GCS + Dual-Regime, Production)** | RTX PRO 6000 Blackwell (`96 GB`, `600 W`) + EPYC 9B45 (`48T`, `176.9 GiB` DDR5) | `Mix-256G` (`6,099–6,155` VRAM + `9,589–9,645` RAM experts, `disk_gb=0.0`, `Shards 1–4` NVMe via HF Xet `~305 MiB/s`, `5–7` `/mnt/hf` HTTP/2, GCS for `>160` bursts only) | `~11.6–15.4 min` engine load (`0 GB` boot GCS egress) | **`391.7–449.1 tok/s`** cold 78K–80K; **`531 tok/s`** mean (`546.7–5,596.9 tok/s` bursts) in 313-round Agent workload | **`42.02 tok/s`** cold benchmark median (`46.64 tok/s` warmed, `57.7 tok/s` peak); **`65.95 tok/s`** median (`P90 97.42 tok/s`) in real Agent sessions |
| **G4 Mode B2 (Single-Disk `/dev/shm` Fallback)** | RTX PRO 6000 Blackwell (`96 GB`) | `Mix-256G` with `110G /dev/shm` for `Shard 00002`, skips `6.7%` cold disk experts (`MAYA_DS4_DISK_SKIP_W=1.01`) | `~15 min` | `~142 tok/s` (`DS4_PROMPT_PICK=length:65536`) | Up to **`48.7 tok/s`** (after `0.97 -> 48.7` fix) |
| **A100 High-RAM (`128g` Measured / `256g` Mode A)** | A100-SXM4 (`80 GB`, `sm_80`) + `12 vCPU` Xeon (`167.1 GiB` RAM) + dual disks (`~585 GB` free) | `Mix-128G` measured; `Mode A` places `Shards 1–3` (`~183 GiB`) on `/mnt/local-scratch` for `100%` `Mix-256G` RAM/VRAM residency without `LD_PRELOAD` | `~15–18 min` | `455 tok/s` mean (`740–1,453 tok/s`) on `128g`; `450–900 tok/s` expected on `256g` | `66.9 tok/s` mean on `128g` (note: higher loop-guard frequency on `128g`) |

Detailed troubleshooting notes covering all eight pitfalls (`DriveFS` `D`-state deadlocks, single-disk OOM, `gcsfuse` `5.1x` read amplification, `nvme_card-pd` `1,860 IOPS` saturation, `DS4_RECENT=0` traps, `65536` output clamping, `--vision on` `0 MiB` idle VRAM, and Colab `24h` / `Error 530` recovery) are documented in [docs/g4-vs-a100-748b-retrospective.md](docs/g4-vs-a100-748b-retrospective.md).

---

## Repository Layout

```text
.
├── .gitignore                             # Excludes real keys, tokens, bucket names, .app bundles, and OS junk
├── LICENSE                                # MIT License + upstream mw00/project-maya attribution
├── README.md
├── SKILL.md                               # Agent skill instructions & tuning reference
├── docs/
│   └── g4-vs-a100-748b-retrospective.md   # Full sanitized A100 vs G4 engineering retrospective
├── macos_app/
│   ├── MayaStudioApp.swift                # Xcode-free AppKit + WKWebView native macOS desktop shell
│   └── build_macos_app.sh                 # Single-command CoreGraphics icon + Universal swiftc + codesign builder
├── src/
│   ├── hf_ro_fuse.c                       # Lightweight read-only FUSE3 mount (/mnt/hf) for HF CDN
│   └── gcs_tls_pread.c                    # Extracted LD_PRELOAD dual-regime HF/GCS + NVMe I/O C source
├── scripts/
│   ├── deploy_from_mac.sh                 # One-command uploader & remote bootstrap via colab-cli
│   ├── start_g4_256g.sh                   # Adaptive Mode A / Mode B1 / Mode B2 runtime launcher
│   ├── keepalive_colab.sh                 # 12-min Jupyter kernel keepalive + tunnel URL sync
│   ├── launch_studio.sh                   # Cross-platform launcher (--web / --daemon / --port / MayaStudio.app)
│   ├── install_skill.sh                   # Installs this folder as a reusable agent skill
│   └── audit_secrets.py                   # Offline secret, PII, and tar header metadata scanner
├── studio/
│   ├── __init__.py
│   ├── __main__.py                        # python3 -m studio entry point (127.0.0.1:18765 + proxy 18766)
│   ├── config_store.py                    # ~/.config/maya-gcs/ credential store, mode catalog & SSE log broker
│   ├── colab_manager.py                   # Colab OAuth, G4 single-shape guard, deploy & read-only attach
│   ├── engine_proxy.py                    # Same-origin transparent reverse proxy & OpenAI /v1 gateway (:18766)
│   ├── server.py                          # Stdlib ThreadingHTTPServer control plane REST + SSE API (:18765)
│   └── static/
│       ├── index.html                     # EasyColab-style 3-column dark workbench HTML
│       ├── styles.css                     # Dark theme (#0B0F17 / #111826), ?shell=macos safe-area gutter
│       └── app.js                         # Zero-build ES6 controller, live telemetry, SSE logs & privacy mask
└── resources/
    ├── maya-g4-runtime.tar.gz             # Prebuilt sm_120 maya-ds4 + patched serve/ + v1.1.56 tools/
    ├── maya-a100-sm80-build.tar.gz        # Prebuilt sm_80 maya-ds4 for A100 High-RAM
    ├── pack-meta-256g.tar.gz              # Pre-built Mix-256G pack index, Engram & tokenizer metadata
    ├── maya-ds4.json                      # Production G4 configuration (DSpark + Vision + Blackwell flags)
    ├── gcs-key.json.example               # Placeholder GCP Service Account JSON template
    ├── gcs-bucket.example                 # Placeholder GCS bucket template
    └── hf-token.example                   # Placeholder Hugging Face token template
```

---

## Quickstart

### 0. Clone Repository

```bash
git clone https://github.com/peterhon168/colab-maya-ds4-256g.git
cd colab-maya-ds4-256g
```

### 1. Place Credentials Outside Git (Recommended)

```bash
mkdir -p ~/.config/maya-gcs
chmod 700 ~/.config/maya-gcs

# Optional for Mode B1 (recommended on G4): same-region GCS service account & bucket name
cp /path/to/your-gcs-service-account.json ~/.config/maya-gcs/gcs-key.json
echo "your-gcs-bucket-name" > ~/.config/maya-gcs/bucket

# Hugging Face read token (for Mode A / Mode B2 or GCS fallback)
echo "hf_your_huggingface_token" > ~/.config/maya-gcs/hf-token

chmod 600 ~/.config/maya-gcs/*
```

> Never commit real credential files into `resources/`. `deploy_from_mac.sh` checks environment variables (`MAYA_GCS_KEY_FILE`, `MAYA_GCS_BUCKET`, `MAYA_HF_TOKEN_FILE` / `HF_TOKEN`), then `~/.config/maya-gcs/`, and finally `.gitignore`-excluded files under `resources/`.

### 2. Provision a Colab Runtime

For **Colab G4 (`RTX PRO 6000 Blackwell 96GB`)**:

```bash
colab new -s easycolab --gpu G4
```

> **Important:** Do **not** pass `--high-mem` with `--gpu G4`. `colab-cli` sends `shape=hm` and Colab rejects it with `HTTP 400: Backend rejected accelerator 'G4'` because G4 already uses the single `Standard` (`176.9 GiB`) machine shape. Only pass `--high-mem` for `A100` (`colab new -s easycolab --gpu A100 --high-mem`).

### 3. Deploy from Your Local Machine

```bash
bash scripts/deploy_from_mac.sh easycolab
```

The script uploads the prebuilt runtime (`~62 MB`), configures Mode A / Mode B1 / Mode B2 automatically, pulls/links `Mix-256G` shards, starts `maya-ds4` + `cloudflared`, and launches `scripts/keepalive_colab.sh` in the background.

If you use a local OpenAI-compatible client config (`~/.pi/agent/models.json`), `keepalive_colab.sh` automatically updates `baseUrl`, `maxTokens` (`65536`), and `input` (`["text", "image"]`) when present, and can also be customized via `PI_MODELS_JSON`, `PI_PROVIDER_KEY`, and `PI_WEB_URL`. If no local config file exists, it still prints the active `https://*.trycloudflare.com` URL and keeps the Colab session alive.

### 4. Monitor Progress & Verify Endpoints

```bash
colab exec -s easycolab << 'EOF'
!tail -n 25 /content/project-maya/maya-ds4.log
!grep -hoE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /content/project-maya/cloudflared.log /tmp/cloudflared.log 2>/dev/null | tail -n 1
EOF
```

Once `ready: http://127.0.0.1:8000/v1` appears, check `/metrics`:

```bash
colab exec -s easycolab << 'EOF'
import json, urllib.request
m = json.loads(urllib.request.urlopen("http://127.0.0.1:8000/metrics", timeout=10).read())
print("images:", m["engine"]["images"], "dspark:", m["engine"]["dspark"], "ram_experts:", m["engine"]["ram_experts"])
if m.get("tiers"):
    print("disk_gb:", m["tiers"]["now"]["disk_gb"])
EOF
```

---

## Maya · Strata Studio 桌面工作台 & WebUI

In addition to CLI scripts, this repository includes **Maya · Strata Studio** — a zero-dependency Python control plane (`http://127.0.0.1:18765`), transparent same-origin reverse proxy / OpenAI gateway (`http://127.0.0.1:18766/v1`), and an Xcode-free native macOS desktop wrapper (`MayaStudio.app`).

### 1. Three-Column Workbench Layout

- **Top Global Bar**: Displays online status, active engine badge (`Project Maya (ds4)` or `Strata Engine (strata)`), GPU chip, quick client guide modal (`示例接入指南`), external WebUI launcher, bilingual `中 / EN` toggle, and **Screen-Recording Privacy Mask (`录屏隐私打码`)**. When launched inside `MayaStudio.app` (`?shell=macos`), the top bar reserves `78px` on the left for native macOS traffic lights.
- **Left Column (Compute Instance & Engine Mode)**:
  - **Colab 算力实例 & 额度**: Google OAuth account status & login modal, GPU selector (`G4 · RTX PRO 6000 · 96GB` without `--high-mem`, `A100 · 80GB High-RAM`, `L4`, `T4`), session name, `⚡ 唤醒实例并部署` / `🔗 无损纳管已运行会话`, CU balance, hourly burn rate, `12m 保活` switch, and confirmation-guarded instance release.
  - **推理引擎与加速模式**: Segmented switcher between **Project Maya (`ds4`)** (5 selectable cards: `Mode B1`, `Mode B1-Pure`, `Mode A`, `Mode B1-GCS`, `Mode B2` + collapsible advanced options) and **Strata Engine (`strata`)**, plus the bottom `~/.config/maya-gcs/` credentials strip.
- **Center Stage (WebUI Console, Telemetry & Client Sync)**:
  - `🖥️ 原生 WebUI 控制台`: Embeds the remote Maya `:8000` or Strata WebUI inside a same-origin `<iframe>` via `http://127.0.0.1:18766/`, or shows the 6-step deployment pipeline and one-click `easycolab` attach card when offline.
  - `📊 实时遥测与对话探针`: Live KPI cards (`Prefill tok/s`, `Decode tok/s`, `VRAM 命中率`, `总请求数`, `活跃队列`), recent requests table, and `/v1/chat/completions` chat probe.
  - `🔌 客户端一键接入`: One-click sync to `~/.pi/agent/models.json` / `pi-web` (`127.0.0.1:30141`) plus copyable snippets for Cursor, Claude Code, and OpenAI SDKs.
- **Right Column (Live Logs & Diagnostics)**:
  - Streams `/api/studio/logs/stream` via SSE with category filters (`全部` / `部署` / `Colab` / `保活` / `命令`), keyword search, and quick diagnostic chips (`nvidia-smi`, `df -h`, remote engine logs, processes/tunnels, Colab quota) plus a custom command input.

### 2. macOS Native `MayaStudio.app` (One-Command Build & Launch)

Requires macOS 13.0+ with Swift CLI (`swiftc`, no Xcode project required) and Python 3.9+:

```bash
# Build Universal Binary (arm64 + x86_64), generate CoreGraphics AppIcon.icns, and ad-hoc sign
bash macos_app/build_macos_app.sh

# Verify bundle signature
codesign --verify --deep --strict MayaStudio.app

# Launch the native desktop app (or double-click MayaStudio.app in Finder)
open MayaStudio.app
```

- **Smart Process Reuse & Safe Exit**: At startup, `MayaStudio.app` probes `127.0.0.1:18765`. If a Studio service is already listening, it reuses it directly; otherwise it launches `python3 -m studio --host 127.0.0.1 --port 18765 --proxy-port 18766 --auto-attach` in the background. On quit, `.app` only sends `SIGTERM` to a backend child process it spawned itself—external services, `keepalive_colab.sh`, and remote Colab VMs are never touched.
- **Standalone Relocation**: `build_macos_app.sh` embeds clean `studio/`, `scripts/`, `src/`, and non-secret `resources/` inside `Contents/Resources/` while resolving `MAYA_STUDIO_ROOT` or parent repo directories dynamically, allowing `MayaStudio.app` to be dragged into `/Applications` without hardcoded `/Users/<username>` paths.

### 3. Cross-Platform Launch (`python3 -m studio` & `launch_studio.sh`)

Run directly on macOS or Linux using only Python 3 standard library modules:

```bash
# Direct Python entry point
python3 -m studio --host 127.0.0.1 --port 18765 --proxy-port 18766 --auto-attach

# Cross-platform wrapper script
bash scripts/launch_studio.sh                 # macOS: opens MayaStudio.app (falls back to --web)
bash scripts/launch_studio.sh --web           # Force Python server + open http://127.0.0.1:18765
bash scripts/launch_studio.sh --daemon        # Start in background and return immediately
bash scripts/launch_studio.sh --port 18765    # Custom control plane port (reuses if already listening)
```

### 4. Non-Destructive Attach to Running `easycolab` Sessions

If you already deployed an active session via CLI (e.g., `easycolab` running `maya-ds4` with `keepalive_colab.sh`), click **`🔗 无损纳管已运行会话`** (or start with `--auto-attach` / `POST /api/studio/colab/attach`). Studio executes a single read-only `colab exec` probe to collect GPU name, `/mnt/hf` and `/mnt/local-scratch` mount status, live tunnel URL, and external `keepalive_colab.sh` PID status, then binds `http://127.0.0.1:18766` immediately without restarting `maya-ds4` or disturbing active inference.

> **G4 Single-Shape Reminder:** Studio enforces `SINGLE_SHAPE_GPUS = {"g4", "h100", "l4"}` and never sends `high_mem` when provisioning G4 runtimes (only `A100` uses `--high-mem`).

### 5. Strata Engine Node Integration

Toggle the left-panel engine selector to **`Strata Engine (strata)`** to connect directly to any local, LAN, or tunneled Strata endpoint (e.g., `http://192.168.x.x:18181` or `https://<random-subdomain>.trycloudflare.com`), or run Colab with `--engine strata`. Studio proxies `/health`, `/status`, `/metrics`, `/v1/models`, `/v1/chat/completions`, and the Strata WebUI through `http://127.0.0.1:18766` with CORS and iframe-friendly headers.

### 6. Security Sanitization & Credential Hygiene

- **Out-of-Repo Credentials**: Studio stores `hf-token`, `gcs-key.json`, `bucket`, and `strata-api-key` strictly inside `~/.config/maya-gcs/` (`0700` directory, `0600` files).
- **Clean Packaging**: `macos_app/build_macos_app.sh` explicitly filters out `gcs-key.json`, `gcs-bucket`, `hf-token`, `*.key`, `*.pem`, `.env*`, `*secret*`, and `*credential*`, and verifies none exist inside `MayaStudio.app` before signing.
- **Screen-Recording Privacy Mask**: Keep **录屏隐私打码 (`ON`)** active during demos to mask emails (`go***@gmail.com`), bucket identifiers, and tunnel subdomains (`https://******.trycloudflare.com`) across the UI.
- **Zero Hardcoded PII**: Never commit real personal `/Users/<username>` paths, tokens, or tunnel subdomains; verify with `python3 scripts/audit_secrets.py`.

---

## Install as a Reusable Coding-Agent Skill

```bash
bash scripts/install_skill.sh
```

This copies the toolkit to `~/.gemini/config/skills/colab-maya-ds4-256g` and symlinks it into `~/.agents/skills`, `~/.codex/skills`, and `~/.claude/skills`.

---

## Pre-Publish Security & Hygiene Audit

Before committing or pushing changes to GitHub, run the offline audit script to verify that no tokens, private keys, GCP emails, live tunnel URLs, local `/Users/<name>` paths, or non-`root` tar headers are present anywhere in tracked files or inside `resources/*.tar.gz`:

```bash
python3 scripts/audit_secrets.py
```

---

## License & Attribution

- Repository scripts, documentation, and `src/gcs_tls_pread.c`: [MIT License](LICENSE).
- Bundled `Project Maya` (`v1.1.56`) runtime binaries, serving layer, and packing tools: upstream [`mw00/project-maya`](https://github.com/mw00/project-maya) (MIT License).
