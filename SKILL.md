---
name: colab-maya-ds4-256g
description: >-
  Deploy and serve DeepSeek-V4.1-Flash-1017 (Mix-256G / abliterated-256g) using Project Maya (maya-ds4)
  on a Google Colab G4 runtime (RTX PRO 6000 Blackwell 96GB VRAM + 176.9GB DDR5 RAM) with Cloudflare Tunnel
  and dual-regime HTTP/2 GCS acceleration, achieving ~42-46.6 tok/s steady decode (~49.5-57.7 tok/s peak),
  392-449 tok/s cold 75K-80K high-entropy prefill, and ~11.6-12.5 min cold GCS boot without compiling CUDA,
  mounting Google Drive, or repacking GGUF.
---

# Colab G4 Project Maya (`maya-ds4`) `Mix-256G` Fast Deployment Skill

Use this skill whenever the user wants to deploy, restart, tune, or expose `DeepSeek-V4.1-Flash-1017` (`Mix-256G` / `abliterated-256g`) with Project Maya (`maya-ds4`) on a Google Colab **G4** runtime (`NVIDIA RTX PRO 6000 Blackwell Server Edition`, `sm_120`, 96 GB VRAM + 176.9 GB DDR5 RAM).

## 1. Bundled Prebuilt Assets (`resources/`)

This skill bundles everything required to skip CUDA compilation (~40 min), skip `pack_gguf.py` (~10 min), and eliminate Google Drive FUSE dependencies (supporting both Colab **G4** `sm_120` and **A100 High-RAM** `sm_80`):

- [maya-g4-runtime.tar.gz](./resources/maya-g4-runtime.tar.gz) (`37 MB`): Pre-compiled Blackwell (`sm_120`) `build/maya-ds4` binary, `maya.py`, `setup.py`, complete `v1.1.56` `tools/` (`tools/*.py` + `tools/ds4/`), `serve/` (patched so `/v1/models` advertises `max_output_tokens: 65536`, `Service.prepare` guarantees at least 16K answer headroom on top of `thinking_budget`, and `DS4_STAT_LOG` telemetry stays active), and runtime data files.
- [maya-a100-sm80-build.tar.gz](./resources/maya-a100-sm80-build.tar.gz): Pre-compiled Ampere (`sm_80`) `maya-ds4` binary + `MAYA-BUILD.json`, automatically extracted by [start_g4_256g.sh](./scripts/start_g4_256g.sh) when running on an A100 runtime.
- [pack-meta-256g.tar.gz](./resources/pack-meta-256g.tar.gz) (`2.3 MB`): Pre-built `Mix-256G/maya-ds4` directory (`tensors.txt`, `engram.bin`, `expert-profile.bin`, G4-calibrated `lane-times.txt`, `ds4.txt`, and `tokenizer/`).
- [maya-ds4.json](./resources/maya-ds4.json): Production-verified G4 configuration (`--prefill-chunk 32768`, `DS4_LENT_RAM_GB=7.5`, `DS4_ENGRAM_THREADS=768`, `DS4_INDEX_TC=1`, `DS4_CPU_PREPARE_ROWS=1`, dual-regime `MAYA_S2_GCS_THRESH=160` + `MAYA_S2_LOCAL_MAX=16`, `DSpark` enabled, `thinking_budget: 16384`).
- [keepalive_colab.sh](./scripts/keepalive_colab.sh): Hardened background Mac daemon (with 90s subprocess kill guards) that refreshes `colab sessions`, pings the Colab Jupyter kernel every 12 minutes so Colab does not reap the VM after 60 minutes idle, and automatically syncs the active `https://*.trycloudflare.com` URL and `maxTokens: 65536` into `~/.pi/agent/models.json` and `pi-web` (`127.0.0.1:30141`).

---

## 2. One-Command Deployment from Mac (~12–15 Minutes Total)

If creating a fresh G4 VM first, run:

```bash
colab new -s easycolab --gpu G4
```

> **IMPORTANT**: **Do NOT pass `--high-mem` with `--gpu G4`** — `colab-cli` appends `&shape=hm`, causing Colab to reject the request (`HTTP 400: Backend rejected accelerator 'G4'`) because G4 only exists in the single `Standard` shape (`176.9 GiB` DDR5 RAM). Always omit `--high-mem` for `G4` (only use `--high-mem` for `A100`).

Given an active `colab` CLI session on a G4 or A100 High-RAM runtime (default session name `easycolab`), run:

```bash
bash ~/.gemini/config/skills/colab-maya-ds4-256g/scripts/deploy_from_mac.sh easycolab
```

### Credential Setup (Keep Secrets Out of Git)

Store your own credentials outside this repository (or use the `.gitignore`-excluded `resources/` filenames):

```bash
mkdir -p ~/.config/maya-gcs
chmod 700 ~/.config/maya-gcs
# Default recommended (Mode B1-Pure, MAYA_S2_GCS_DISABLE=1): only hf-token is required ($0 GCS)
echo "hf_your_huggingface_token" > ~/.config/maya-gcs/hf-token

# Optional (only when enabling Mode B1 single-region GCS burst; avoid `us` Multi-Region to prevent egress charges)
cp path/to/your-service-account.json ~/.config/maya-gcs/gcs-key.json
echo "your-single-region-gcs-bucket" > ~/.config/maya-gcs/bucket
chmod 600 ~/.config/maya-gcs/*
```

By default, [deploy_from_mac.sh](./scripts/deploy_from_mac.sh) and Studio run **Mode B1-Pure (`MAYA_S2_GCS_DISABLE=1`)** via `/mnt/hf` (`hf_ro_fuse` + local NVMe) using `hf-token` alone (zero GCS dependency or egress). To opt into dual-regime GCS burst in CLI mode, pass `MAYA_S2_GCS_DISABLE=0 bash scripts/deploy_from_mac.sh easycolab`; only when neither `hf-token` nor GCS credentials are present does [start_g4_256g.sh](./scripts/start_g4_256g.sh) fall back to Mode B2 (G4 `/dev/shm`).

---

### What [deploy_from_mac.sh](./scripts/deploy_from_mac.sh) and [start_g4_256g.sh](./scripts/start_g4_256g.sh) Do:
1. **Enables GPU Persistence & Uploads Prebuilt Runtime (`~3s`)**: Enables `nvidia-smi -pm 1` (`600.00 W` TDP preserved on G4) and pushes `maya-g4-runtime.tar.gz`, `maya-a100-sm80-build.tar.gz` (when present), `maya-ds4.json`, `pack-meta-256g.tar.gz`, `start_g4_256g.sh`, `src/hf_ro_fuse.c`, `src/gcs_tls_pread.c`, and HF credentials (plus GCS credentials only when `MAYA_S2_GCS_DISABLE=0` / Mode B1) to `/tmp` on the Colab VM.
2. **Adaptive Dual-Disk / HF-FUSE+Pure / Optional GCS Burst / RAMDisk Layout (`Mode B1-Pure` default)**:
   - **Mode A (A100 Dual-Disk, `/mnt/local-scratch` ≥ 200G)**: Sets `HF_HOME=/mnt/local-scratch/hf-cache`, symlinks `Shards 00001..00003` (`~183 GiB`) into `/mnt/local-scratch/maya-shards`, downloads `Shards 00004..00007` + `dspark` + `vision` to `/content/maya-models/`, keeping system RAM free (`DS4_RAM_MARGIN_GB=6.0`, `DS4_ENGRAM_CACHE_MB=4096`, `DS4_LENT_RAM_GB=4.5`, `--prefill-chunk 16384`).
   - **Mode B1-Pure (Default Recommended when `HF_TOKEN` is set, `MAYA_S2_GCS_DISABLE=1`) & Optional Mode B1 (Same Single-Region GCS Burst)**:
     - Compiles `src/hf_ro_fuse.c` (`fuse3` + `libcurl`) and mounts `/mnt/hf` read-only backed by Hugging Face's presigned GCP CDN URLs (`us.gcp.cdn.hf.co`, `$0.00/GB`, refreshed every `1200s` into `/dev/shm/.maya_hf_urls` by `maya_url_token_refresher.sh`), pulls `Shards 00001..00004`, `dspark/`, and `vision/` onto local NVMe SSD via Hugging Face Xet (`HF_XET_HIGH_PERFORMANCE=1`, `~305 MiB/s`, `$0.00/GB`), and symlinks **only `Shards 00005, 00006, 00007`** (`~131 GiB`) from `/mnt/hf/Mix-256G/` (`0.00 GB` GCS boot egress!). Set `MAYA_SHARDS57_SOURCE=gcs` + `MAYA_PREFER_GCS_DOWNLOAD=1` only if you want legacy `/mnt/gcs` `gcsfuse` cold boot. **`Shard 00002` must never live on FUSE** (see §3.6).
     - Compiles **`gcs_tls_pread.so`** (`-lcurl -ldl -lpthread`) with two complementary bypasses:
       1. **FUSE `> 256 KB` Direct HTTPS HTTP/2 `Range` Bypass (`fuse_direct_pread64`)** + `2 MB` per-thread TLS metadata windows: intercepts `/mnt/hf/` (direct `us.gcp.cdn.hf.co`, `$0/GB`) and `/mnt/gcs/` directly in C, eliminating FUSE kernel read amplification while keeping `hf_ro_fuse` `mmap()` page faults bit-exact (`100%` VRAM + RAM residency, `disk_gb=0.0`).
       2. **`Shard 00002` 3-Tier Dual-Regime Engram Accelerator (`s2_pread64`)** *(automatically enabled when `/tmp/gcs-key.json` + `/tmp/gcs-bucket` are also supplied; otherwise `MAYA_S2_GCS_DISABLE=1`)*:
          - **Tier 1 (`mincore` Page Cache)**: Zero-syscall resident check + `memcpy` directly from `MAP_SHARED` `mmap`.
          - **Tier 2 (`MAYA_S2_GCS_THRESH=160` Decode Local Path)**: When concurrent misses `tot <= 160` (covering `DSpark` multi-token verify decode: `<= 6 tokens × 24 heads = 144 <= 160`), **100%** of cold misses stay on local `nvme_card-pd` (`0` network RTT stragglers, `0` GCS egress, full Linux Page Cache population), delivering **`42.02 tok/s` `median(last 6)` / `49.35 tok/s` max** on clean unpatched 10-round benchmarks (up to `46.6 tok/s` median / `~57.7 tok/s` peak when caches settle).
          - **Tier 3 (`MAYA_S2_LOCAL_MAX=16` + `8×8` HTTP/2 `curl_multi` GCS Pool)**: During long-context prefill bursts (`DS4_ENGRAM_THREADS=768`, `tot > 160`), `16` threads saturate `nvme_card-pd` (`~1,860` random `4 KB` IOPS, `QD=16` sweet spot) while **`752` threads** stream across `64` multiplexed HTTP/2 TLS connections over Google Titanium `50 Gbps` gVNIC (`~11,000+ rows/s`, typically only a few GB per 24h), raising cold `75K–80K` non-repeating prefill from **`73 tok/s` to `391.74–449.1 tok/s`** (`5.4x–6.1x` speedup)!
   - **Mode B2 (G4 Single-Disk + `/dev/shm` fallback)**: Remounts `/dev/shm` to `110G` for `Shard 00002` (`103 GiB` Engram) and puts remaining shards on `/content/maya-models/` (`DS4_RAM_MARGIN_GB=8.0`, `MAYA_DS4_DISK_SKIP_W=1.01`).
   - **Never** reads model shards from `/content/drive` (Google Drive FUSE deadlocks in `D` state under multi-threaded `pread` / `POSIX_FADV_WILLNEED`).
3. **Restores Pre-Packed Metadata (`~1s`) & Safely Restarts `maya.py`**: Extracts `pack-meta-256g.tar.gz`, cleanly stops prior processes via `/proc` cmdline matching (never self-killing `bash -lc` with `pkill -f`), and starts `maya.py` with `LD_PRELOAD=/content/project-maya/gcs_tls_pread.so`.
4. **Starts `cloudflared` & Mac Keepalive (`keepalive_colab.sh`)**: Preserves healthy tunnels or spawns `cloudflared`, and runs `keepalive_colab.sh` every 12 minutes to prevent Colab idle disconnect and keep `~/.pi/agent/models.json` + `pi-web` (`127.0.0.1:30141`) updated.

---

## 3. Critical Performance & Memory Parameters (`maya-ds4.json`)

Do **not** remove these flags/env vars on a single-GPU G4 VM with `Mix-256G` (`Mode B1`):

```json
{
 "args": [
  "--pack", "/content/maya-models/DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-256G/maya-ds4",
  "--max-context", "262144",
  "--tp", "1",
  "--threads", "on",
  "--dspark", "on",
  "--vision", "on",
  "--reserve-mib", "700",
  "--mmap-experts", "off",
  "--prefill-chunk", "32768",
  "--verbose",
  "--serve",
  "--no-expert-cache"
 ],
 "sampling": {
  "temperature": 0.6,
  "top_p": 0.95,
  "min_p": 0.05
 },
 "env": {
  "DS4_ENGRAM_CACHE_MB": "4096",
  "DS4_LENT_RAM_GB": "7.5",
  "DS4_FLOW_COPY_DMA": "1",
  "DS4_STAT_LOG": "1",
  "DS4_RAM_MARGIN_GB": "6.0",
  "DS4_ENGRAM_THREADS": "768",
  "DS4_YOCO_CONE": "1",
  "MAYA_DS4_EG_RANDOM": "1",
  "MAYA_DS4_RESTORE_TAIL": "0",
  "MAYA_S2_LOCAL_MAX": "16",
  "MAYA_S2_GCS_THRESH": "160",
  "DS4_INDEX_TC": "1",
  "DS4_CPU_PREPARE_ROWS": "1"
 }
}
```

### Why Each Setting Is Required:
1. **`--no-expert-cache` + `DS4_RAM_MARGIN_GB=6.0`**:
   - Keeps `6,140–6,155` hottest experts (`89.86 GB` total VRAM experts; `5,756–5,771` non-lent + `13` slots/layer lent headroom, `366 MiB` free) locked in VRAM and all remaining `9,589–9,604` CPU-lane experts (`145.4 GB`) pinned in DDR5 RAM (`100%` VRAM + RAM residency, `disk_gb=0.0`).
2. **Do NOT set `DS4_AHEAD=0`, `DS4_RECENT=0`, or `DS4_BORROW=0`**:
   - Forcing `DS4_RECENT=0` costs ~30% of decode speed (`8/16/24/32` slots = `59.0/61.5/62.2/62.9 tok/s`). Leave all three unset.
3. **`DS4_ENGRAM_THREADS=768` + `MAYA_S2_GCS_THRESH=160` + `MAYA_S2_LOCAL_MAX=16` (and `MAYA_DS4_EG_RANDOM=1`)**:
   - **Never lower `DS4_ENGRAM_THREADS` to `64`**: Colab G4's local `/` NVMe (`nvme_card-pd`) is hard-capped at `~1,860` random `4 KB` IOPS (`QD=16`). Raising `DS4_ENGRAM_THREADS` to `768` feeds `gcs_tls_pread.so`'s `8×8` HTTP/2 GCS pool (`~11,000+ rows/s`) during long prefill (`391.7–449.1 tok/s` vs `144.5 tok/s` at `64` threads).
   - **Never raise `MAYA_S2_LOCAL_MAX` above `16–20` without keeping `MAYA_S2_GCS_THRESH`**: Setting `MAYA_S2_LOCAL_MAX=160` unconditionally traps `160` prefill threads in an `86 ms` local NVMe queue and cuts `75K` cold prefill nearly in half (`449 -> 239 tok/s`). Conversely, unconditionally routing decode overflow at `>16` to GCS stalls decode verify barriers on `~12–45 ms` HTTP/2 network RTT (`35.2 tok/s`). The dual-regime gate (`MAYA_S2_GCS_THRESH=160` + `MAYA_S2_LOCAL_MAX=16`) achieves both simultaneously (`391.74 tok/s` cold `77.8K` prefill + `42.02 tok/s` median / `49.35 tok/s` max decode on the exact same unpatched process!).
   - `MAYA_DS4_EG_RANDOM=1` passes `POSIX_FADV_RANDOM` on `Shard 00002` opens, eliminating `128 KB` kernel readahead waste per `264 B` random lookup.
4. **`--prefill-chunk 32768` + `DS4_LENT_RAM_GB=7.5` + `DS4_FLOW_COPY_DMA=1` + `DS4_YOCO_CONE=1` + `MAYA_DS4_RESTORE_TAIL=0`**:
   - Doubles max GPU prefill chunk from `16384` to `32768` (`~7.72 GB` borrowed VRAM during prompts) and expands pinned lent-expert RAM slots from `4.5 GB` to `7.5 GB` (`428` places / `8.0 GB` pinned) so `417+` handed-back experts restore cleanly from RAM in `~110 ms` (`0` from files).
   - `DS4_YOCO_CONE=1` prunes early KV-only rows inside YOCO layers `20–39` on long prompts; `MAYA_DS4_RESTORE_TAIL=0` avoids slow file-backed tail restore-point stalls. `DS4_FLOW_COPY_DMA=1` enables async H2D DMA (`56.8 GB/s`) so prefill wait time on file reads stays `0 ms`.
5. **Blackwell (`sm_120`) Acceleration (`DS4_INDEX_TC=1` + `DS4_CPU_PREPARE_ROWS=1` + Auto `DS4_PDL`)**:
   - `DS4_INDEX_TC=1` moves DeepSeek-V4.1's `kKvFp4p` DSA Lightning Indexer onto Blackwell 5th-Gen Tensor Cores (`+3% / +6% / +10%` long-prompt speedup at `8K / 32K / 64K`). `DS4_PDL` (Programmatic Dependent Launch) auto-enables for `sm_120`. `DS4_CPU_PREPARE_ROWS=1` pre-validates all `4` CPU MXFP4/IQ row types during load.
6. **Shard Placement (`Shard 00002` local NVMe only) & `DS4_ENGRAM_CACHE_MB=4096`**:
   - `Shard 00002` (`110.6 GB`, `layers.{1,14}.engram.embed.weight`) serves random `144–264 B` rows and must stay on local NVMe (`~1,860–22,000 rows/s`); `gcsfuse` alone serves only `15–18 rows/s` (`8 tok/s` collapse). Shards `5/6/7` are sequential load-time weights, safe on `/mnt/gcs` via the `>256 KB` direct HTTPS HTTP/2 bypass.
   - Do **not** enable `DS4_ENGRAM_PREFETCH` or `DS4_EG_ZONE_KB` (they spawn zone-read storms that starve the 24-thread CPU lane).
7. **The 24-Thread AVX512 CPU Lane Is the Decode Ceiling**:
   - `9,589` CPU-lane experts run on `24` Zen 5 `AVX512-VNNI` threads (`226–233 us/row`, `147.7 GB/s` RAM lane bandwidth), while GPU power during decode sits around `~170 W` of `600 W`. After `3–4` warm-up requests settling `EgRowCache` (`16.27M` slots / `4 GiB`) and Linux Page Cache, steady decode reaches **`~42–46+ tok/s` (`~58 tok/s` peak)** — the true single-card G4 hardware ceiling for `Mix-256G`.

---

## 4. Verification & Monitoring Commands

Check loading progress and get the Cloudflare Tunnel URL:
```bash
colab exec -s easycolab << 'EOF'
!tail -n 25 /content/project-maya/maya-ds4.log
!grep -hoE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /content/project-maya/cloudflared.log /tmp/cloudflared.log 2>/dev/null | tail -n 1
EOF
```

Verify `/metrics` after a request:
```bash
colab exec -s easycolab << 'EOF'
import urllib.request, json
with urllib.request.urlopen("http://127.0.0.1:8000/metrics", timeout=10) as r:
    m = json.loads(r.read().decode())
print(json.dumps(m.get("tiers", {}).get("now", {}), indent=2))
EOF
```

**Verify Steady Decode Speed** (first `3–4` runs warm caches; take `10` requests and check `median(last 6)` >= `41 tok/s`):
```bash
colab exec -s easycolab --timeout 600 << 'EOF'
import json, time, urllib.request, statistics
url = "http://127.0.0.1:8000/v1/chat/completions"
def run(n=400):
    body = json.dumps({"model": "deepseek-v4.1-flash-abliterated", "messages": [{"role": "user", "content": f"Explain black holes in depth, {n} words."}], "max_tokens": n, "temperature": 0.7}).encode()
    t0 = time.perf_counter()
    d = json.load(urllib.request.urlopen(urllib.request.Request(url, body, {"Content-Type": "application/json"}), timeout=300))
    el = time.perf_counter() - t0
    return d["usage"]["completion_tokens"] / el
res = [run() for _ in range(10)]
print(" ".join(f"{x:.2f}" for x in res), "| median(last 6) %.2f" % statistics.median(res[4:]))
EOF
```

**Verify True Cold `~75K–80K` High-Entropy Non-Repeating Prefill (`392–449 tok/s`)**:
Drop `Shard 00002` Page Cache via `os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)`, assemble ~288 KB of UUID-salted source text (`cached_tokens == 0`), and measure `prompt_tokens / wall_s` with `"max_tokens": 1`.

**Check Shard Placement**:
```bash
colab exec -s easycolab << 'EOF'
!ls -l /content/maya-models/DeepSeek-V4.1-Flash-1017-abliterated-GGUF/Mix-256G/*.gguf
!P=$(pgrep -f build/maya-ds4 | head -1); ls -l /proc/$P/fd | grep -c gguf; ls -l /proc/$P/fd | grep gguf | grep -c /mnt/gcs
EOF
```

---

## 5. RTX PRO 6000 Blackwell (96GB) Hardware, Community Benchmarks & Optimization Reference

- **Verified G4 VM Specs (`easycolab`, `g4-standard-48`)**:
  - **GPU (`GB202`, `sm_120`)**: `NVIDIA RTX PRO 6000 Blackwell Server Edition` — `24,064` CUDA cores, `752` 5th-Gen Tensor Cores (`2nd-Gen Transformer Engine` with hardware `FP4 / FP6 / FP8 / MXFP4`), `97,887 MiB` (`96 GB`) GDDR7 ECC (`512-bit`, `28 Gbps`), PCIe Gen 5 x16 (`64 GB/s` theoretical; **`56.8 GB/s` H2D DMA** measured), **no NVLink**.
  - **Server vs Workstation TDP & Bandwidth**: Standalone rack Server Editions default to a `400W` passive thermal envelope (`~1,597 GB/s` effective GDDR7 bandwidth), whereas active-cooled Workstation Editions run at `600W` (`1,792 GB/s` bandwidth, `~125 TFLOPS` FP32). **Colab G4 unlocks the full `600.00 W` power cap** (`Min 300W`, `Default 600W`, `Max 600W`), delivering Workstation-class peak boost clocks and full `1,792 GB/s` bandwidth.
  - **Host Platform**: 5th-Gen `AMD EPYC 9B45` ("Turin", Zen 5, `24C / 48T`, 1 NUMA node, `AVX512 / AVX512-VNNI`), `176.9 GiB` usable DDR5 RAM (`12`-channel Turin platform theoretical `~614–680+ GB/s`; `maya-ds4` CPU lane `147.7 GB/s` across `24` threads), local `/` NVMe (`nvme_card-pd`, `~1,860` random `4 KB` IOPS cap), Google Titanium `50 Gbps` gVNIC.
- **Community & Production Benchmark Reference (`r/LocalLLaMA`, `r/BlackwellPerformance`, Google Cloud G4)**:
  - **Dense / Full-VRAM Models (`<= 96 GB`, Compute & GDDR7-Bound)**:
    - `Llama-3 8B` (`Q4`): `~200–210 tok/s` single-stream decode.
    - `Qwen / Llama 27B–32B` (`AWQ / FP8 / NVFP4` on `vLLM` / `SGLang`): `3,800–9,000+ tok/s` prefill and `8,400+ tok/s` batched throughput.
    - `Llama-3.3 70B` (`Q4_K_M`): `1,250–1,770+ tok/s` `pp512` prefill and `~24–35 tok/s` `tg128` single-stream decode.
  - **Hybrid Offloaded Frontier MoE (`748B DeepSeek-V4.1-Flash` on `project-maya`)**:
    - Community workstation single-GPU decode spans `~30–81 tok/s` depending on quant and host bandwidth (`~149 tok/s` on dual-5090 / multi-GPU).
    - On single-card Colab G4 `Mix-256G` (`355 GB` pack), `6,140–6,155` hottest experts (`89.86 GB`) reside in VRAM and `9,589–9,604` (`145.4 GB`) run on the `24`-thread Zen 5 `AVX512-VNNI` lane, delivering **`42.02–46.6 tok/s` steady (`49.35–57.7 tok/s` peak) decode** and **`391.7–449.1 tok/s` cold `75K–80K` prefill** (via dual-regime `8×8` HTTP/2 GCS acceleration).
- **Power-Scaling & Topology Takeaways**:
  - **Asymmetric TDP Scaling (`r/BlackwellPerformance`)**: Long-context prefill is compute-bound and scales strongly up to `600W`, whereas `T=1` decode is GDDR7-bandwidth-bound and hits an efficiency knee around **`300–350W`** (capping at `300–350W` retains `92–97%` decode speed for ~30% lower power; **always keep `600W` unlocked + `nvidia-smi -pm 1` on G4** so prefill runs at full speed).
  - **PCIe Gen 5 (No NVLink)**: Multi-card TP across PCIe Gen 5 incurs AllReduce fabric overhead (Google Titanium direct P2P helps multi-GPU G4 clusters), whereas on single-card hybrid MoE (`project-maya`), `T=1` PCIe streaming regresses decode by `+8.4%` (`38.25 vs 35.29 ms/tok`), so pinning 100% of active weights across `96 GB` VRAM + `145.4 GB` DDR5 RAM is strictly optimal.

---

## 6. Maya · Strata Studio 桌面工作台 & WebUI

Beyond headless CLI scripts, the repository ships **Maya · Strata Studio** (`studio/`, `macos_app/`, `scripts/launch_studio.sh`): a Python 3 standard-library control plane (`127.0.0.1:18765`), transparent same-origin reverse proxy & OpenAI `/v1` gateway (`127.0.0.1:18766`), and an Xcode-free native macOS desktop wrapper (`MayaStudio.app`).

### Three-Column Workbench Architecture
- **Top Control Bar**: Connection status pill, engine & GPU badges, `示例接入指南`, external browser launcher, `中 / EN` toggle, and **Screen-Recording Privacy Mask (`录屏隐私打码`)**. In `MayaStudio.app` (`?shell=macos`), `78px` left padding clears the native macOS traffic-light buttons.
- **Left Panel (`Colab 算力实例 & 额度` + `推理引擎与加速模式`)**:
  - Google OAuth PKCE login/refresh, GPU selector (`G4` never sends `--high-mem`; only `A100` uses `--high-mem`), session input, `⚡ 唤醒实例并部署`, `🔗 无损纳管已运行会话`, CU balance / hourly burn rate, `12m 保活` switch, and confirmation-guarded stop.
  - Segmented engine switcher: **Project Maya (`ds4`)** with 5 selectable mode cards (`Mode B1-Pure` default recommended, `Mode B1` optional single-region GCS burst, `Mode A`, `Mode B1-GCS`, `Mode B2` + collapsible `HF Repo` / `MAYA_S2_GCS_THRESH` / `MAYA_S2_LOCAL_MAX` / context / `--vision` options) vs. **Strata Engine (`strata`)**, plus the `~/.config/maya-gcs/` credentials status bar.
- **Center Stage**:
  - `🖥️ 原生 WebUI 控制台`: Same-origin `<iframe>` pointing to `http://127.0.0.1:18766/` (proxied Maya `:8000` or Strata Dashboard with `X-Frame-Options` / `frame-ancestors` stripped and upstream `Host`/`Origin` rewritten for `_own_page()` compatibility), or a 6-step deployment pipeline + one-click `easycolab` attach card when offline.
  - `📊 实时遥测与对话探针`: Live `Prefill tok/s`, `Decode tok/s`, `VRAM 命中率`, `总请求数`, `活跃队列`, recent requests table, and `/v1/chat/completions` probe.
  - `🔌 客户端一键接入`: One-click sync to `~/.pi/agent/models.json` / `pi-web` (`127.0.0.1:30141`) and copyable configs for Cursor, Claude Code, and OpenAI SDKs.
- **Right Panel**: Real-time `/api/studio/logs/stream` SSE viewer with category filters, search, and diagnostic quick-exec chips (`nvidia-smi`, `df -h`, remote engine log tail, processes/tunnels, Colab quota, custom exec).

### Build & Launch Commands

```bash
# 1. macOS native MayaStudio.app (Xcode-free swiftc + CoreGraphics AppIcon.icns + ad-hoc codesign)
bash macos_app/build_macos_app.sh
codesign --verify --deep --strict MayaStudio.app
open MayaStudio.app

# 2. Cross-platform Python CLI launch (macOS / Linux, stdlib only)
python3 -m studio --host 127.0.0.1 --port 18765 --proxy-port 18766 --auto-attach

# 3. Unified launcher script
bash scripts/launch_studio.sh                 # macOS: opens MayaStudio.app (or falls back to --web)
bash scripts/launch_studio.sh --web           # Force Python WebUI server + open default browser
bash scripts/launch_studio.sh --daemon        # Start background daemon and return immediately
bash scripts/launch_studio.sh --port 18765    # Custom control plane port
```

- **Reuse & Safe Exit**: Both `MayaStudio.app` and `scripts/launch_studio.sh` probe `127.0.0.1:18765` first; if an existing Studio server is running, they reuse it directly without killing external workflows. On exit, `MayaStudio.app` only terminates (`SIGTERM`) a child `studio` process that it spawned itself, leaving external services, `keepalive_colab.sh`, and remote Colab VMs untouched.

### Non-Destructive `easycolab` Attach & Strata Engine Support
- **Read-Only Attach (`POST /api/studio/colab/attach`)**: Inspects an already-running `easycolab` session via a single read-only `colab exec` probe (GPU model, `/mnt/hf` / `/mnt/local-scratch` mounts, `maya-ds4` / `strata` status, latest `cloudflared` tunnel URL) and checks local `pgrep -f "keepalive_colab.sh"` status without interrupting active inference or restarting the VM.
- **Strata Engine (`strata`)**: Switch to **Strata Engine** in the left panel or call `POST /api/studio/engine/configure` to connect directly to a LAN/remote Strata endpoint (e.g. `http://192.168.x.x:18181` or `https://<random-subdomain>.trycloudflare.com`), or deploy on Colab with `--engine strata`. The `:18766` reverse proxy forwards `/health`, `/status`, `/metrics`, `/v1/models`, `/v1/chat/completions`, and the Strata dashboard seamlessly.

### Credential Security & Sanitization Rules
- Store user secrets strictly outside Git in `~/.config/maya-gcs/` (`chmod 700` dir, `chmod 600` files: `hf-token`, `gcs-key.json`, `bucket`, `strata-api-key`).
- `build_macos_app.sh` excludes `gcs-key.json`, `gcs-bucket`, `hf-token`, `*.key`, `*.pem`, `.env*`, `*secret*`, and `*credential*` from `MayaStudio.app`, and avoids hardcoding `/Users/<username>` paths by resolving `MAYA_STUDIO_ROOT`, `.app` parent directories, or `Contents/Resources/` dynamically.
- Keep **录屏隐私打码** enabled when capturing screenshots/recordings, and always run `python3 scripts/audit_secrets.py` before committing (`Findings count: 0`).
