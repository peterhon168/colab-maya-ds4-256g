#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="/content/project-maya"
DRIVE_DIR="${MAYA_DRIVE_BACKUP_DIR:-/content/drive/MyDrive/maya-backups/project-maya}"
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)"
echo "检测到 GPU: $GPU_NAME"
nvidia-smi -pm 1 2>/dev/null || true

# 判断是否有 /mnt/local-scratch 副盘 (A100 双盘模式 vs G4 单盘+/dev/shm模式)
if mountpoint -q /mnt/local-scratch 2>/dev/null || [ -d /mnt/local-scratch ]; then
  SCRATCH_FREE_GB=$(df -BG /mnt/local-scratch | awk 'NR==2 {gsub("G","",$4); print $4}')
else
  SCRATCH_FREE_GB=0
fi

MODEL_ROOT="/content/maya-models/DeepSeek-V4.1-Flash-1017-abliterated-GGUF"
mkdir -p "$MODEL_ROOT/Mix-256G" "$MODEL_ROOT/dspark" "$MODEL_ROOT/vision" "$WORK_DIR/build"

GCS_BUCKET="$(cat /tmp/gcs-bucket 2>/dev/null | tr -d '[:space:]' || true)"

if [ -z "${HF_TOKEN:-}" ]; then
  if [ -f /tmp/hf-token ]; then
    export HF_TOKEN="$(tr -d '[:space:]' < /tmp/hf-token)"
    mkdir -p /root/.cache/huggingface
    printf '%s' "$HF_TOKEN" > /root/.cache/huggingface/token
  elif [ -f /root/.cache/huggingface/token ]; then
    export HF_TOKEN="$(tr -d '[:space:]' < /root/.cache/huggingface/token)"
  fi
fi

write_refresher_script() {
  mkdir -p "$WORK_DIR"
  cat > "$WORK_DIR/maya_url_token_refresher.sh" << 'TEOF'
#!/usr/bin/env bash
set -u
unset LD_PRELOAD

HF_REPO="${MAYA_HF_REPO:-orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF}"
HF_URLS_FILE="${MAYA_HF_URLS_PATH:-/dev/shm/.maya_hf_urls}"
GCS_TOK_FILE="/dev/shm/.maya_gcs_token"
GCLOUD_BIN="/tools/google-cloud-sdk/bin/gcloud"
[ -x "$GCLOUD_BIN" ] || GCLOUD_BIN="$(command -v gcloud || true)"

get_hf_token() {
  local t="${HF_TOKEN:-}"
  if [ -z "$t" ] && [ -f /tmp/hf-token ]; then
    t="$(tr -d '[:space:]' < /tmp/hf-token 2>/dev/null || true)"
  fi
  if [ -z "$t" ] && [ -f /root/.cache/huggingface/token ]; then
    t="$(tr -d '[:space:]' < /root/.cache/huggingface/token 2>/dev/null || true)"
  fi
  printf '%s' "$t"
}

refresh_hf_once() {
  local hftok
  hftok="$(get_hf_token)"
  [ -n "$hftok" ] || return 1
  HF_TOKEN="$hftok" python3 - "$HF_REPO" "$HF_URLS_FILE" << 'PY'
import os, re, sys, time, urllib.error, urllib.parse, urllib.request

repo, out_path = sys.argv[1], sys.argv[2]
tok = os.environ.get("HF_TOKEN", "").strip()
if not tok:
    sys.exit(1)

class NoRedir(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

op = urllib.request.build_opener(NoRedir)
lines = []
for idx in (5, 6, 7):
    rel = f"Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-0000{idx}-of-00007.gguf"
    url = f"https://huggingface.co/{repo}/resolve/main/{rel}"
    last_err = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, method="GET", headers={"Authorization": f"Bearer {tok}"})
            cdn_url = None
            try:
                resp = op.open(req, timeout=20)
                resp.close()
            except urllib.error.HTTPError as e:
                if e.code in (301, 302, 303, 307, 308):
                    loc = e.headers.get("Location", "")
                    if loc:
                        cdn_url = urllib.parse.urljoin(url, loc)
                else:
                    raise
            if not cdn_url:
                raise RuntimeError(f"Missing redirect Location for {rel}")
            probe = urllib.request.Request(cdn_url, headers={"Range": "bytes=0-0"})
            with urllib.request.urlopen(probe, timeout=20) as r2:
                if r2.status != 206:
                    raise RuntimeError(f"Expected HTTP 206 on probe, got {r2.status}")
                cr = r2.headers.get("Content-Range", "")
                m = re.match(r"bytes\s+0-0/(\d+)", cr)
                if not m:
                    raise RuntimeError(f"Bad Content-Range: {cr}")
                sz = int(m.group(1))
                _ = r2.read(1)
            lines.append(f"{rel}\t{sz}\t{cdn_url}\n")
            last_err = None
            break
        except Exception as exc:
            last_err = exc
            time.sleep(1.5 * (attempt + 1))
    if last_err is not None:
        raise last_err

tmp = f"{out_path}.tmp.{os.getpid()}"
with open(tmp, "w") as f:
    f.writelines(lines)
os.chmod(tmp, 0o600)
os.replace(tmp, out_path)
PY
}

refresh_gcs_once() {
  [ -n "$GCLOUD_BIN" ] && [ -f /tmp/gcs-key.json ] || return 1
  local tok
  tok="$(CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=/tmp/gcs-key.json "$GCLOUD_BIN" auth print-access-token 2>/dev/null | tr -d '[:space:]')"
  [ -n "$tok" ] || return 1
  local tmp="${GCS_TOK_FILE}.tmp.$$"
  umask 077
  printf '%s\n' "$tok" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$GCS_TOK_FILE"
}

case "${1:-}" in
  --hf-only)
    refresh_hf_once
    exit $?
    ;;
  --gcs-only)
    refresh_gcs_once
    exit $?
    ;;
  --once)
    rc=0
    if [ -n "$(get_hf_token)" ]; then
      refresh_hf_once || rc=1
    fi
    if [ -f /tmp/gcs-key.json ]; then
      refresh_gcs_once || rc=1
    fi
    exit $rc
    ;;
esac

while true; do
  refresh_hf_once || true
  refresh_gcs_once || true
  sleep 1200
done
TEOF
  chmod 700 "$WORK_DIR/maya_url_token_refresher.sh"
  ln -sf "$WORK_DIR/maya_url_token_refresher.sh" "$WORK_DIR/maya_gcs_token_refresher.sh"
}

write_hf_ro_fuse_c() {
  cat > /tmp/hf_ro_fuse.c << 'HCEOF'
/*
 * hf_ro_fuse.c — Lightweight read-only FUSE3 filesystem backed by presigned Hugging Face CDN URLs.
 *
 * Build on Linux (Google Colab x86_64):
 *   gcc -Wall -Wextra -Werror -O2 src/hf_ro_fuse.c -o hf_ro_fuse \
 *       $(pkg-config --cflags --libs fuse3 libcurl) -lpthread
 *
 * Runtime configuration (via environment variables before fuse_main daemonizes):
 *   HF_RO_FUSE_URLS       Tab-separated table: <rel_path>\t<size_bytes>\t<url>
 *                         (default: /dev/shm/.maya_hf_urls)
 *   HF_RO_FUSE_REFRESHER  Optional command executed on HTTP 401/403 (rate-limited to 5s)
 *                         (default: /content/project-maya/maya_url_token_refresher.sh --hf-only)
 */

#define _GNU_SOURCE
#define FUSE_USE_VERSION 31

#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <fuse3/fuse.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MAX_HF_FILES 16
#define HF_URL_MAX 8192

struct HfEntry {
    char rel_path[512];
    char dir_name[256];
    char base_name[256];
    uint64_t size;
    char url[HF_URL_MAX];
};

struct HfWriteCtx {
    unsigned char *dst;
    size_t cap;
    size_t got;
    int overflow;
};

static char g_urls_path[PATH_MAX] = "/dev/shm/.maya_hf_urls";
static char g_refresher_cmd[PATH_MAX] = "/content/project-maya/maya_url_token_refresher.sh --hf-only";

static pthread_mutex_t g_tbl_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_refresh_lock = PTHREAD_MUTEX_INITIALIZER;
static struct HfEntry g_entries[MAX_HF_FILES];
static int g_n_entries = 0;
static struct timespec g_last_mtime;
static uint64_t g_last_stat_ns = 0;
static uint64_t g_last_refresh_ns = 0;

static pthread_once_t g_curl_key_once = PTHREAD_ONCE_INIT;
static pthread_key_t g_curl_key;

static uint64_t mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int parse_urls_file(const char *path, struct HfEntry *out, int *out_n, struct timespec *out_mtim) {
    FILE *fp = fopen(path, "r");
    if (!fp) return -1;

    struct stat st;
    if (fstat(fileno(fp), &st) != 0) {
        fclose(fp);
        return -1;
    }

    int count = 0;
    char line[16384];
    while (fgets(line, sizeof(line), fp) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = '\0';
        }
        if (len == 0 || line[0] == '#') continue;

        char *t1 = strchr(line, '\t');
        if (!t1) continue;
        char *t2 = strchr(t1 + 1, '\t');
        if (!t2) continue;

        *t1 = '\0';
        *t2 = '\0';

        const char *rel = line;
        while (*rel == '/') rel++;
        const char *sz_str = t1 + 1;
        const char *url = t2 + 1;

        if (!rel[0] || !sz_str[0] || !url[0]) continue;
        if (strlen(rel) >= sizeof(out[0].rel_path)) continue;
        if (strlen(url) >= sizeof(out[0].url)) continue;

        char *endp = NULL;
        errno = 0;
        unsigned long long sz = strtoull(sz_str, &endp, 10);
        if (errno != 0 || endp == sz_str || (endp && *endp != '\0') || sz == 0) continue;

        if (count >= MAX_HF_FILES) break;
        struct HfEntry *e = &out[count];
        memset(e, 0, sizeof(*e));
        snprintf(e->rel_path, sizeof(e->rel_path), "%s", rel);
        e->size = (uint64_t)sz;
        snprintf(e->url, sizeof(e->url), "%s", url);

        const char *slash = strchr(rel, '/');
        if (slash) {
            size_t dlen = (size_t)(slash - rel);
            if (dlen == 0 || dlen >= sizeof(e->dir_name) || strchr(slash + 1, '/') != NULL) continue;
            memcpy(e->dir_name, rel, dlen);
            e->dir_name[dlen] = '\0';
            if (!slash[1] || strlen(slash + 1) >= sizeof(e->base_name)) continue;
            snprintf(e->base_name, sizeof(e->base_name), "%s", slash + 1);
        } else {
            if (strlen(rel) >= sizeof(e->base_name)) continue;
            e->dir_name[0] = '\0';
            snprintf(e->base_name, sizeof(e->base_name), "%s", rel);
        }
        count++;
    }
    fclose(fp);

    if (count <= 0) return -1;
    *out_n = count;
    if (out_mtim) *out_mtim = st.st_mtim;
    return 0;
}

static int reload_urls_if_needed(int force_refresh) {
    if (force_refresh && g_refresher_cmd[0]) {
        pthread_mutex_lock(&g_refresh_lock);
        uint64_t now = mono_ns();
        if (now - g_last_refresh_ns >= 5000000000ULL) {
            int rc = system(g_refresher_cmd);
            (void)rc;
            g_last_refresh_ns = mono_ns();
        }
        pthread_mutex_unlock(&g_refresh_lock);
    }

    uint64_t now = mono_ns();
    pthread_mutex_lock(&g_tbl_lock);
    int need_check = force_refresh || (g_n_entries == 0) || ((now - g_last_stat_ns) >= 2000000000ULL);
    if (need_check) {
        g_last_stat_ns = now;
        struct stat st;
        if (stat(g_urls_path, &st) == 0) {
            int mtime_changed = (st.st_mtim.tv_sec != g_last_mtime.tv_sec ||
                                 st.st_mtim.tv_nsec != g_last_mtime.tv_nsec);
            if (force_refresh || g_n_entries == 0 || mtime_changed) {
                struct HfEntry tmp[MAX_HF_FILES];
                int tmp_n = 0;
                struct timespec mt;
                if (parse_urls_file(g_urls_path, tmp, &tmp_n, &mt) == 0) {
                    memcpy(g_entries, tmp, (size_t)tmp_n * sizeof(tmp[0]));
                    g_n_entries = tmp_n;
                    g_last_mtime = mt;
                }
            }
        }
    }
    int ok = (g_n_entries > 0);
    pthread_mutex_unlock(&g_tbl_lock);
    return ok ? 0 : -1;
}

static int lookup_file(const char *fuse_path, struct HfEntry *out) {
    if (!fuse_path || fuse_path[0] != '/' || !fuse_path[1]) return -1;
    const char *rel = fuse_path + 1;
    (void)reload_urls_if_needed(0);
    pthread_mutex_lock(&g_tbl_lock);
    for (int i = 0; i < g_n_entries; i++) {
        if (strcmp(g_entries[i].rel_path, rel) == 0) {
            if (out) *out = g_entries[i];
            pthread_mutex_unlock(&g_tbl_lock);
            return 0;
        }
    }
    pthread_mutex_unlock(&g_tbl_lock);
    return -1;
}

static int is_known_dir(const char *fuse_path) {
    if (!fuse_path || fuse_path[0] != '/') return 0;
    if (fuse_path[1] == '\0') return 1;
    const char *dir = fuse_path + 1;
    (void)reload_urls_if_needed(0);
    pthread_mutex_lock(&g_tbl_lock);
    for (int i = 0; i < g_n_entries; i++) {
        if (g_entries[i].dir_name[0] && strcmp(g_entries[i].dir_name, dir) == 0) {
            pthread_mutex_unlock(&g_tbl_lock);
            return 1;
        }
    }
    pthread_mutex_unlock(&g_tbl_lock);
    return 0;
}

static void destroy_tls_curl(void *ptr) {
    CURL *eh = (CURL *)ptr;
    if (eh) curl_easy_cleanup(eh);
}

static void make_curl_key(void) {
    pthread_key_create(&g_curl_key, destroy_tls_curl);
}

static CURL *get_tls_curl(void) {
    pthread_once(&g_curl_key_once, make_curl_key);
    CURL *eh = (CURL *)pthread_getspecific(g_curl_key);
    if (!eh) {
        eh = curl_easy_init();
        if (!eh) return NULL;
        curl_easy_setopt(eh, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(eh, CURLOPT_TCP_NODELAY, 1L);
        curl_easy_setopt(eh, CURLOPT_TCP_KEEPALIVE, 1L);
        curl_easy_setopt(eh, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS);
        curl_easy_setopt(eh, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(eh, CURLOPT_CONNECTTIMEOUT_MS, 5000L);
        curl_easy_setopt(eh, CURLOPT_TIMEOUT_MS, 60000L);
        curl_easy_setopt(eh, CURLOPT_BUFFERSIZE, 524288L);
        curl_easy_setopt(eh, CURLOPT_HTTPHEADER, NULL);
        if (pthread_setspecific(g_curl_key, eh) != 0) {
            curl_easy_cleanup(eh);
            return NULL;
        }
    }
    return eh;
}

static size_t hf_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    size_t total = size * nmemb;
    struct HfWriteCtx *ctx = (struct HfWriteCtx *)userdata;
    if (total > ctx->cap - ctx->got) {
        ctx->overflow = 1;
        return 0;
    }
    memcpy(ctx->dst + ctx->got, ptr, total);
    ctx->got += total;
    return total;
}

static void *hf_init(struct fuse_conn_info *conn, struct fuse_config *cfg) {
    (void)conn;
    curl_global_init(CURL_GLOBAL_DEFAULT);
    if (cfg) {
        cfg->kernel_cache = 1;
        cfg->attr_timeout = 3600.0;
        cfg->entry_timeout = 3600.0;
        cfg->negative_timeout = 60.0;
    }
    return NULL;
}

static int hf_getattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi) {
    (void)fi;
    memset(stbuf, 0, sizeof(*stbuf));

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode = S_IFDIR | 0555;
        stbuf->st_nlink = 3;
        return 0;
    }
    if (is_known_dir(path)) {
        stbuf->st_mode = S_IFDIR | 0555;
        stbuf->st_nlink = 2;
        return 0;
    }

    struct HfEntry ent;
    if (lookup_file(path, &ent) == 0) {
        stbuf->st_mode = S_IFREG | 0444;
        stbuf->st_nlink = 1;
        stbuf->st_size = (off_t)ent.size;
        stbuf->st_blocks = (blkcnt_t)((ent.size + 511ULL) / 512ULL);
        return 0;
    }
    return -ENOENT;
}

static int hf_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                      off_t offset, struct fuse_file_info *fi,
                      enum fuse_readdir_flags flags) {
    (void)offset;
    (void)fi;
    (void)flags;

    if (strcmp(path, "/") != 0 && !is_known_dir(path)) return -ENOENT;

    (void)reload_urls_if_needed(0);
    filler(buf, ".", NULL, 0, (enum fuse_fill_dir_flags)0);
    filler(buf, "..", NULL, 0, (enum fuse_fill_dir_flags)0);

    pthread_mutex_lock(&g_tbl_lock);
    if (strcmp(path, "/") == 0) {
        char seen_dirs[MAX_HF_FILES][256];
        int n_seen = 0;
        for (int i = 0; i < g_n_entries; i++) {
            if (g_entries[i].dir_name[0]) {
                int dup = 0;
                for (int j = 0; j < n_seen; j++) {
                    if (strcmp(seen_dirs[j], g_entries[i].dir_name) == 0) {
                        dup = 1;
                        break;
                    }
                }
                if (!dup) {
                    snprintf(seen_dirs[n_seen++], sizeof(seen_dirs[0]), "%s", g_entries[i].dir_name);
                    filler(buf, g_entries[i].dir_name, NULL, 0, (enum fuse_fill_dir_flags)0);
                }
            } else {
                filler(buf, g_entries[i].base_name, NULL, 0, (enum fuse_fill_dir_flags)0);
            }
        }
    } else {
        const char *dir = path + 1;
        for (int i = 0; i < g_n_entries; i++) {
            if (strcmp(g_entries[i].dir_name, dir) == 0) {
                filler(buf, g_entries[i].base_name, NULL, 0, (enum fuse_fill_dir_flags)0);
            }
        }
    }
    pthread_mutex_unlock(&g_tbl_lock);
    return 0;
}

static int hf_open(const char *path, struct fuse_file_info *fi) {
    if ((fi->flags & O_ACCMODE) != O_RDONLY) return -EROFS;
    if (lookup_file(path, NULL) != 0) return -ENOENT;
    fi->keep_cache = 1;
    return 0;
}

static int hf_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    (void)fi;
    if (offset < 0) return -EINVAL;

    struct HfEntry ent;
    if (lookup_file(path, &ent) != 0) return -ENOENT;
    if ((uint64_t)offset >= ent.size) return 0;

    size_t want = size;
    uint64_t remain = ent.size - (uint64_t)offset;
    if ((uint64_t)want > remain) want = (size_t)remain;
    if (want > (size_t)INT_MAX) want = (size_t)INT_MAX;
    if (want == 0) return 0;

    CURL *eh = get_tls_curl();
    if (!eh) return -EIO;

    char range[64];
    snprintf(range, sizeof(range), "%llu-%llu",
             (unsigned long long)offset,
             (unsigned long long)((uint64_t)offset + (uint64_t)want - 1ULL));

    for (int attempt = 0; attempt < 3; attempt++) {
        struct HfWriteCtx ctx;
        ctx.dst = (unsigned char *)buf;
        ctx.cap = want;
        ctx.got = 0;
        ctx.overflow = 0;

        curl_easy_setopt(eh, CURLOPT_URL, ent.url);
        curl_easy_setopt(eh, CURLOPT_RANGE, range);
        curl_easy_setopt(eh, CURLOPT_WRITEFUNCTION, hf_write_cb);
        curl_easy_setopt(eh, CURLOPT_WRITEDATA, &ctx);

        CURLcode res = curl_easy_perform(eh);
        long code = 0;
        if (res == CURLE_OK) {
            curl_easy_getinfo(eh, CURLINFO_RESPONSE_CODE, &code);
        }
        if (res == CURLE_OK && code == 206 && !ctx.overflow && ctx.got == want) {
            return (int)want;
        }
        int force = (res == CURLE_OK && (code == 401 || code == 403));
        (void)reload_urls_if_needed(force);
        (void)lookup_file(path, &ent);
    }
    return -EIO;
}

static const struct fuse_operations hf_oper = {
    .init    = hf_init,
    .getattr = hf_getattr,
    .readdir = hf_readdir,
    .open    = hf_open,
    .read    = hf_read,
};

int main(int argc, char *argv[]) {
    const char *env_urls = getenv("HF_RO_FUSE_URLS");
    if (env_urls && env_urls[0]) {
        snprintf(g_urls_path, sizeof(g_urls_path), "%s", env_urls);
    }
    const char *env_ref = getenv("HF_RO_FUSE_REFRESHER");
    if (env_ref) {
        snprintf(g_refresher_cmd, sizeof(g_refresher_cmd), "%s", env_ref);
    }

    if (reload_urls_if_needed(0) != 0) {
        fprintf(stderr, "hf_ro_fuse: failed to load URLs from %s\n", g_urls_path);
        return 1;
    }

    return fuse_main(argc, argv, &hf_oper, NULL);
}
HCEOF
}

SHARDS57_SOURCE="${MAYA_SHARDS57_SOURCE:-auto}"
if [ "$SHARDS57_SOURCE" = "auto" ]; then
  if [ -n "${HF_TOKEN:-}" ]; then
    SHARDS57_SOURCE="hf"
  elif [ -f /tmp/gcs-key.json ] && [ -n "$GCS_BUCKET" ]; then
    SHARDS57_SOURCE="gcs"
  else
    SHARDS57_SOURCE="shm"
  fi
fi

REMOTE_MOUNT_DIR=""
GCS_MOUNT_DIR=""
USE_HF_FUSE=0
PREFER_GCS_DOWNLOAD="0"
S2_GCS_DISABLE=""

if [ "$SCRATCH_FREE_GB" -ge 200 ]; then
  echo "[模式 A: A100 双盘均衡模式 (检测到 /mnt/local-scratch 可用 ${SCRATCH_FREE_GB}G)]"
  echo "  -> 将 Shard 00001/00002/00003 (~183 GiB) 存入 /mnt/local-scratch/maya-shards 并软链，释放 / 与全部 167 GiB 系统内存！"
  SCRATCH_SHARDS_DIR="/mnt/local-scratch/maya-shards"
  mkdir -p "$SCRATCH_SHARDS_DIR" /mnt/local-scratch/hf-cache
  if [ -z "${HF_TOKEN:-}" ] && [ -f /root/.cache/huggingface/token ]; then
    export HF_TOKEN="$(cat /root/.cache/huggingface/token)"
  fi
  export HF_HOME="/mnt/local-scratch/hf-cache"
  S2_DIR=""
  PREFILL_CHUNK="16384"
  RAM_MARGIN="6.0"
  DISK_SKIP_W="0"
  PROMPT_PICK=""
  ENGRAM_CACHE_MB="4096"
  LENT_RAM_GB="4.5"
  FLOW_COPY_DMA="1"
  ENGRAM_THREADS=""
  YOCO_CONE=""
  EG_RANDOM=""
  RESTORE_TAIL=""
  S2_LOCAL_MAX=""
  S2_GCS_THRESH=""
  INDEX_TC=""
  CPU_PREPARE_ROWS="1"
elif [ "$SHARDS57_SOURCE" = "hf" ] && [ -n "${HF_TOKEN:-}" ]; then
  echo "[模式 B1: G4 零冷启 GCS 流量 (HF FUSE /mnt/hf + HTTP/2 直连加速)]"
  echo "  -> Shards 1-4、dspark、vision 通过 Hugging Face Xet 免费高速拉取至本地 NVMe (\$0.00/GB)；"
  echo "     Shards 5-7 (~131 GiB) 挂载只读 FUSE3 /mnt/hf 并经由 HTTP/2 Range 直连旁路读取 us.gcp.cdn.hf.co (\$0.00/GB)；"
  if [ -f /tmp/gcs-key.json ] && [ -n "$GCS_BUCKET" ]; then
    echo "     Shard 00002 保持双模态门控 (Decode <=160 走本地 NVMe / 长文本 Prefill >160 溢流至 8×8 HTTP/2 GCS Pool)。"
  else
    echo "     未提供 GCS 凭据，Shard 00002 纯走本地 NVMe，仍实现 100% RAM/VRAM 常驻 (disk_gb=0.0)。"
  fi
  if ! command -v fusermount3 >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1 || ! command -v pkg-config >/dev/null 2>&1 || \
     [ ! -f /usr/include/fuse3/fuse.h ] || { [ ! -f /usr/include/x86_64-linux-gnu/curl/curl.h ] && [ ! -f /usr/include/curl/curl.h ]; }; then
    echo "  -> 安装 fuse3 libfuse3-dev libcurl4-openssl-dev pkg-config..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fuse3 libfuse3-dev libcurl4-openssl-dev pkg-config
  fi
  write_refresher_script
  "$WORK_DIR/maya_url_token_refresher.sh" --once || true
  "$WORK_DIR/maya_url_token_refresher.sh" --hf-only
  if ! pgrep -f "maya_url_token_refresher.sh" >/dev/null 2>&1; then
    nohup "$WORK_DIR/maya_url_token_refresher.sh" >/dev/null 2>&1 < /dev/null &
  fi
  [ -f /tmp/hf_ro_fuse.c ] || write_hf_ro_fuse_c
  gcc -Wall -Wextra -Werror -O2 /tmp/hf_ro_fuse.c -o "$WORK_DIR/hf_ro_fuse.tmp" $(pkg-config --cflags --libs fuse3 libcurl) -lpthread
  mv -f "$WORK_DIR/hf_ro_fuse.tmp" "$WORK_DIR/hf_ro_fuse"
  mkdir -p /mnt/hf
  if mountpoint -q /mnt/hf 2>/dev/null && timeout 10 ls /mnt/hf/Mix-256G >/dev/null 2>&1; then
    echo "  -> /mnt/hf 已处于健康挂载状态，复用现有 hf_ro_fuse。"
  else
    fusermount3 -u /mnt/hf 2>/dev/null || umount -l /mnt/hf 2>/dev/null || true
    HF_RO_FUSE_URLS="/dev/shm/.maya_hf_urls" \
    HF_RO_FUSE_REFRESHER="$WORK_DIR/maya_url_token_refresher.sh --hf-only" \
      "$WORK_DIR/hf_ro_fuse" -o ro /mnt/hf
    sleep 0.5
    timeout 10 ls /mnt/hf/Mix-256G >/dev/null
  fi
  SCRATCH_SHARDS_DIR=""
  S2_DIR=""
  USE_HF_FUSE=1
  REMOTE_MOUNT_DIR="/mnt/hf"
  GCS_MOUNT_DIR=""
  PREFER_GCS_DOWNLOAD="${MAYA_PREFER_GCS_DOWNLOAD:-0}"
  PREFILL_CHUNK="32768"
  RAM_MARGIN="6.0"
  DISK_SKIP_W="0"
  PROMPT_PICK=""
  ENGRAM_CACHE_MB="4096"
  LENT_RAM_GB="7.5"
  FLOW_COPY_DMA="1"
  YOCO_CONE="1"
  EG_RANDOM="1"
  RESTORE_TAIL="0"
  INDEX_TC="1"
  CPU_PREPARE_ROWS="1"
  if [ -f /tmp/gcs-key.json ] && [ -n "$GCS_BUCKET" ]; then
    ENGRAM_THREADS="768"
    S2_LOCAL_MAX="16"
    S2_GCS_THRESH="160"
    S2_GCS_DISABLE=""
  else
    ENGRAM_THREADS=""
    S2_LOCAL_MAX=""
    S2_GCS_THRESH=""
    S2_GCS_DISABLE="1"
  fi
elif [ -f /tmp/gcs-key.json ] && [ -n "$GCS_BUCKET" ]; then
  echo "[模式 B1-GCS: G4 + gcsfuse 全量内存 + HTTP/2 直连加速模式 (兼容回退)]"
  echo "  -> Shard 00002 (110.6 GiB Engram 随机行表) 放本地 NVMe；"
  echo "     Shard 00005/6/7 (~141 GiB 专家权重) 挂载 /mnt/gcs 并经由 >256KB HTTP/2 Range 直连旁路读取；"
  echo "     热运行时 Shard 00002 经 mincore -> 双模态门控 (Decode 纯走本地 NVMe / 768 线程 Prefill 溢流至 8×8 HTTP/2 50Gbps GCS Pool)。"
  if ! command -v gcsfuse >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg lsb-release curl fuse3
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt gcsfuse-$(lsb_release -cs) main" > /etc/apt/sources.list.d/gcsfuse.list
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcsfuse
  fi
  mkdir -p /mnt/gcs
  if mountpoint -q /mnt/gcs 2>/dev/null && timeout 10 ls /mnt/gcs/Mix-256G >/dev/null 2>&1; then
    echo "  -> /mnt/gcs 已处于健康挂载状态，复用现有 gcsfuse。"
  else
    fusermount -u /mnt/gcs 2>/dev/null || umount -l /mnt/gcs 2>/dev/null || true
    GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcs-key.json gcsfuse \
      --implicit-dirs \
      -o ro \
      --sequential-read-size-mb 200 \
      --max-conns-per-host 0 \
      --stat-cache-ttl 24h \
      --type-cache-ttl 24h \
      "$GCS_BUCKET" /mnt/gcs
  fi
  SCRATCH_SHARDS_DIR=""
  S2_DIR=""
  REMOTE_MOUNT_DIR="/mnt/gcs"
  GCS_MOUNT_DIR="/mnt/gcs"
  PREFER_GCS_DOWNLOAD="${MAYA_PREFER_GCS_DOWNLOAD:-1}"
  PREFILL_CHUNK="32768"
  RAM_MARGIN="6.0"
  DISK_SKIP_W="0"
  PROMPT_PICK=""
  ENGRAM_CACHE_MB="4096"
  LENT_RAM_GB="7.5"
  FLOW_COPY_DMA="1"
  ENGRAM_THREADS="768"
  YOCO_CONE="1"
  EG_RANDOM="1"
  RESTORE_TAIL="0"
  S2_LOCAL_MAX="16"
  S2_GCS_THRESH="160"
  INDEX_TC="1"
  CPU_PREPARE_ROWS="1"
  S2_GCS_DISABLE=""
else
  echo "[模式 B2: 单盘 + /dev/shm 模式 (G4 236G 无凭据兜底)]"
  echo "  -> 扩容 /dev/shm 至 110G 存放 Shard 00002 (103GiB Engram表)..."
  mount -o remount,size=110G /dev/shm
  SCRATCH_SHARDS_DIR=""
  S2_DIR="/dev/shm"
  PREFILL_CHUNK="16384"
  RAM_MARGIN="8.0"
  DISK_SKIP_W="1.01"
  PROMPT_PICK="length:65536"
  ENGRAM_CACHE_MB=""
  LENT_RAM_GB=""
  FLOW_COPY_DMA="1"
  ENGRAM_THREADS=""
  YOCO_CONE=""
  EG_RANDOM=""
  RESTORE_TAIL=""
  S2_LOCAL_MAX=""
  S2_GCS_THRESH=""
  INDEX_TC="1"
  CPU_PREPARE_ROWS="1"
fi

echo "[2/6] 恢复 maya-ds4 运行环境..."
if [ -f /tmp/maya-g4-runtime.tar.gz ]; then
  tar -xzf /tmp/maya-g4-runtime.tar.gz -C "$WORK_DIR/"
fi
cp -f /tmp/start_g4_256g.sh "$WORK_DIR/start_g4_256g.sh" 2>/dev/null || true

# 如果是 A100 (非 Blackwell)，优先使用本地上传的 sm_80 预编译包，其次回退 Google Drive 备份
if ! echo "$GPU_NAME" | grep -qi "Blackwell"; then
  if [ -f /tmp/maya-a100-sm80-build.tar.gz ]; then
    echo "检测到非 Blackwell GPU ($GPU_NAME)，从 /tmp/maya-a100-sm80-build.tar.gz 恢复 sm_80 maya-ds4..."
    tar -xzf /tmp/maya-a100-sm80-build.tar.gz -C "$WORK_DIR/build/"
  elif [ -f "$WORK_DIR/maya-a100-sm80-build.tar.gz" ]; then
    echo "检测到非 Blackwell GPU ($GPU_NAME)，从 $WORK_DIR/maya-a100-sm80-build.tar.gz 恢复 sm_80 maya-ds4..."
    tar -xzf "$WORK_DIR/maya-a100-sm80-build.tar.gz" -C "$WORK_DIR/build/"
  elif [ -f "$DRIVE_DIR/build/maya-ds4" ]; then
    echo "检测到非 Blackwell GPU ($GPU_NAME)，从 Google Drive 恢复 A100 (sm_80) 预编译 maya-ds4..."
    cp -f "$DRIVE_DIR/build/maya-ds4" "$WORK_DIR/build/maya-ds4"
    cp -f "$DRIVE_DIR/build/MAYA-BUILD.json" "$WORK_DIR/build/MAYA-BUILD.json" 2>/dev/null || true
  else
    echo "警告: 当前为非 Blackwell GPU ($GPU_NAME)，未找到 sm_80 预编译包且未挂载 Google Drive ($DRIVE_DIR/build/maya-ds4)！"
  fi
fi
chmod +x "$WORK_DIR/build/maya-ds4"
rm -f "$WORK_DIR/build/MAYA-BUILD.json"

# serve/server.py 默认吞掉引擎的 `STAT ` 行，导致服务模式下拿不到逐 token 分解
# (engram_ms / vram_hit / ram_fetch 全部不可见)。这里做一次幂等补丁，只放行 STAT 行。
if [ -f "$WORK_DIR/serve/server.py" ] && ! grep -q 'DS4_STAT_LOG' "$WORK_DIR/serve/server.py"; then
  python3 - "$WORK_DIR/serve/server.py" << 'PY'
import sys
p = sys.argv[1]
src = open(p).read()
anchor = '            if line.startswith("END "):'
patch = ('            if line.startswith("STAT ") and os.environ.get("DS4_STAT_LOG") == "1":\n'
         '                print(line.rstrip(), flush=True)\n')
if anchor in src:
    src = src.replace(anchor, patch + anchor, 1)
    open(p, 'w').write(src)
    print("[patch] serve/server.py: STAT lines now forwarded when DS4_STAT_LOG=1")
else:
    print("[patch] serve/server.py: anchor not found, STAT forwarding skipped (harmless)")
PY
fi

if [ ! -x /usr/local/bin/cloudflared ]; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

echo "[3/6] 准备 Python 运行环境 (.venv)..."
if ! "$WORK_DIR/.venv/bin/python" -c "import huggingface_hub, hf_xet, tokenizers, aiohttp, numpy, jinja2, regex, PIL, psutil, yaml, tqdm, requests, jsonschema, pynvml" 2>/dev/null; then
  rm -rf "$WORK_DIR/.venv"
  if python3 -c "import huggingface_hub, hf_xet, tokenizers, aiohttp, numpy, jinja2, regex, PIL, psutil, yaml, tqdm, requests, jsonschema, pynvml" 2>/dev/null; then
    mkdir -p "$WORK_DIR/.venv/bin"
    ln -sf "$(command -v python3)" "$WORK_DIR/.venv/bin/python"
    ln -sf "$(command -v python3)" "$WORK_DIR/.venv/bin/python3"
  elif command -v uv >/dev/null 2>&1; then
    uv venv "$WORK_DIR/.venv"
    uv pip install --python "$WORK_DIR/.venv/bin/python" huggingface_hub hf-xet hf_transfer tokenizers aiohttp numpy jinja2 regex pillow psutil pyyaml tqdm requests "jsonschema>=4.18,<5" nvidia-ml-py
  else
    python3 -m venv "$WORK_DIR/.venv"
    "$WORK_DIR/.venv/bin/pip" install -q -U pip huggingface_hub hf-xet hf_transfer tokenizers aiohttp numpy jinja2 regex pillow psutil pyyaml tqdm requests "jsonschema>=4.18,<5" nvidia-ml-py
  fi
fi

echo "[4/6] 高速拉取 Mix-256G 模型分片..."
if [ ! -d "$WORK_DIR/tools/ds4" ] || [ ! -f "$WORK_DIR/tools/maya_import.py" ] || [ ! -f "$WORK_DIR/setup.py" ]; then
  echo "  -> 补齐 $WORK_DIR/tools 与 setup.py (v1.1.56 sparse checkout)..."
  rm -rf /tmp/pm-tools
  git clone --depth 1 --filter=blob:none --sparse https://github.com/mw00/project-maya.git /tmp/pm-tools
  git -C /tmp/pm-tools sparse-checkout set --no-cone /tools /setup.py
  (git -C /tmp/pm-tools fetch --depth 1 origin 22fc101 && git -C /tmp/pm-tools checkout -f 22fc101) >/dev/null 2>&1 || true
  mkdir -p "$WORK_DIR/tools"
  cp -a /tmp/pm-tools/tools/. "$WORK_DIR/tools/"
  cp /tmp/pm-tools/setup.py "$WORK_DIR/setup.py"
  rm -rf /tmp/pm-tools
fi
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1
export HF_XET_CACHE=/tmp/hf-xet-cache
export SCRATCH_SHARDS_DIR S2_DIR REMOTE_MOUNT_DIR GCS_MOUNT_DIR PREFER_GCS_DOWNLOAD GCS_BUCKET

"$WORK_DIR/.venv/bin/python" - << 'PY'
import os, shutil, subprocess, sys, types
from pathlib import Path
from huggingface_hub import hf_hub_download

repo = "orcarouter/DeepSeek-V4.1-Flash-1017-abliterated-GGUF"
model_root = "/content/maya-models/DeepSeek-V4.1-Flash-1017-abliterated-GGUF"
scratch_shards_dir = os.environ.get("SCRATCH_SHARDS_DIR", "")
remote_mount_dir = os.environ.get("REMOTE_MOUNT_DIR", "")
gcs_mount_dir = os.environ.get("GCS_MOUNT_DIR", "")
prefer_gcs = os.environ.get("PREFER_GCS_DOWNLOAD", "0") == "1"
gcs_bucket = os.environ.get("GCS_BUCKET", "").strip()
if not gcs_bucket and os.path.isfile("/tmp/gcs-bucket"):
    gcs_bucket = open("/tmp/gcs-bucket").read().strip()
gcs_key_file = "/tmp/gcs-key.json"
gcloud_bin = "/tools/google-cloud-sdk/bin/gcloud" if os.path.isfile("/tools/google-cloud-sdk/bin/gcloud") else shutil.which("gcloud")
s2_dir = os.environ.get("S2_DIR", "/dev/shm")
token = os.environ.get("HF_TOKEN") or None

def pull_from_gcs(rel_path, dest_path):
    if not (gcs_bucket and os.path.isfile(gcs_key_file) and gcloud_bin):
        return False
    if os.path.isfile(dest_path) and not os.path.islink(dest_path) and os.path.getsize(dest_path) > 0:
        return True
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    if os.path.lexists(dest_path):
        os.remove(dest_path)
    tmp_dl = dest_path + ".gcs-part"
    if os.path.lexists(tmp_dl):
        os.remove(tmp_dl)
    print(f"Downloading {rel_path} from GCS to local NVMe...", flush=True)
    env = os.environ.copy()
    env["CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE"] = gcs_key_file
    rc = subprocess.run([gcloud_bin, "storage", "cp", f"gs://{gcs_bucket}/{rel_path}", tmp_dl], env=env).returncode
    if rc == 0 and os.path.isfile(tmp_dl) and os.path.getsize(tmp_dl) > 0:
        os.replace(tmp_dl, dest_path)
        return True
    if os.path.lexists(tmp_dl):
        os.remove(tmp_dl)
    return False

if scratch_shards_dir:
    scratch_files = [
        f"Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-0000{i}-of-00007.gguf"
        for i in [2, 1, 3]
    ]
    ssd_files = [
        f"Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-0000{i}-of-00007.gguf"
        for i in [4, 5, 6, 7]
    ]
    for f in scratch_files:
        target = os.path.join(scratch_shards_dir, os.path.basename(f))
        if not os.path.exists(target) or os.path.getsize(target) < 1_000_000_000:
            print(f"Downloading {f} to {scratch_shards_dir}...")
            hf_hub_download(repo_id=repo, filename=f, local_dir=scratch_shards_dir, token=token)
            nested = os.path.join(scratch_shards_dir, f)
            if os.path.exists(nested) and not os.path.exists(target):
                os.rename(nested, target)
        link_path = os.path.join(model_root, f)
        if os.path.lexists(link_path):
            os.remove(link_path)
        os.symlink(target, link_path)
    for f in ssd_files:
        target = os.path.join(model_root, f)
        if os.path.islink(target):
            os.remove(target)
        if not os.path.exists(target):
            print(f"Downloading {f} to local SSD...")
            hf_hub_download(repo_id=repo, filename=f, local_dir=model_root, token=token)
elif remote_mount_dir:
    # Shard 00002 is the two Engram embed tables (55.3 GiB each, 144 B rows read at
    # random) - it MUST be local: remote FUSE serves ~17 random rows/s, local NVMe ~22 000.
    # Shards 5/6/7 are expert weights read as large blocks while loading, then RAM resident,
    # so they are safe on /mnt/hf (free HF CDN) or /mnt/gcs (legacy).
    remote_files = [
        f"Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-0000{i}-of-00007.gguf"
        for i in [5, 6, 7]
    ]
    ssd_files = [
        f"Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-0000{i}-of-00007.gguf"
        for i in [1, 2, 3, 4]
    ]
    for f in remote_files:
        rem_path = os.path.join(remote_mount_dir, f)
        assert os.path.exists(rem_path), f"Missing {rem_path} in mount {remote_mount_dir}!"
        link_path = os.path.join(model_root, f)
        if os.path.lexists(link_path):
            os.remove(link_path)
        os.symlink(rem_path, link_path)
        print(f"Symlinked {f} -> {rem_path}")
    for f in ssd_files:
        target = os.path.join(model_root, f)
        if os.path.islink(target):
            os.remove(target)
        if os.path.isfile(target) and os.path.getsize(target) > 0:
            continue
        got = False
        if prefer_gcs:
            got = pull_from_gcs(f, target)
        if not got:
            print(f"Downloading {f} to local SSD via HF (free Xet/CDN)...", flush=True)
            try:
                hf_hub_download(repo_id=repo, filename=f, local_dir=model_root, token=token)
                got = os.path.isfile(target) and os.path.getsize(target) > 0
            except Exception as exc:
                print(f"HF download failed for {f}: {exc}", flush=True)
        if not got and not prefer_gcs:
            got = pull_from_gcs(f, target)
        assert got and os.path.isfile(target), f"Failed to download {f}"
else:
    s2_name = "Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-00002-of-00007.gguf"
    s2_target = os.path.join(s2_dir, os.path.basename(s2_name))
    if not os.path.exists(s2_target) or os.path.getsize(s2_target) < 100_000_000_000:
        print(f"Downloading Shard 00002 (103 GiB) to {s2_dir}...")
        hf_hub_download(repo_id=repo, filename=s2_name, local_dir=s2_dir, token=token)
        nested = os.path.join(s2_dir, s2_name)
        if os.path.exists(nested) and not os.path.exists(s2_target):
            os.rename(nested, s2_target)

    s2_link = os.path.join(model_root, s2_name)
    if os.path.lexists(s2_link):
        os.remove(s2_link)
    os.symlink(s2_target, s2_link)

    files = [
        f"Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-0000{i}-of-00007.gguf"
        for i in [1, 3, 4, 5, 6, 7]
    ]
    for f in files:
        target = os.path.join(model_root, f)
        if os.path.islink(target):
            os.remove(target)
        if not os.path.exists(target):
            print(f"Downloading {f} to local SSD...")
            hf_hub_download(repo_id=repo, filename=f, local_dir=model_root, token=token)

dspark_dir = Path(model_root) / "dspark"
dspark_dir.mkdir(parents=True, exist_ok=True)
if prefer_gcs:
    for rel in ("dspark/dspark.bin", "dspark/dspark.json"):
        pull_from_gcs(rel, os.path.join(model_root, rel))
if not ((dspark_dir / "dspark.bin").is_file() and (dspark_dir / "dspark.json").is_file()):
    print("Preparing dspark/dspark.bin via hf_hub_download...")
    import json
    man = json.load(open("/content/project-maya/tools/ds4/download_gguf.json"))["maya"]
    for fpath in man["drafter"]["files"]:
        hf_hub_download(
            repo_id=man["repo"],
            filename=fpath,
            revision=man["revision"],
            local_dir=model_root,
            token=token,
        )
    assert (dspark_dir / "dspark.bin").is_file(), "dspark.bin missing after download"

vision_dir = Path(model_root) / "vision"
vision_dir.mkdir(parents=True, exist_ok=True)
if prefer_gcs:
    for rel in ("vision/vision.bin", "vision/vision.json"):
        pull_from_gcs(rel, os.path.join(model_root, rel))
if not ((vision_dir / "vision.bin").is_file() and (vision_dir / "vision.json").is_file()):
    print("Preparing vision/vision.bin from BF16 mmproj...")
    shm_free = shutil.disk_usage("/dev/shm").free if os.path.isdir("/dev/shm") else 0
    mmproj_tmp = Path("/dev/shm/mmproj" if shm_free >= 3 * 1024**3 else "/tmp/mmproj")
    mmproj_tmp.mkdir(parents=True, exist_ok=True)
    mmproj_path = hf_hub_download(
        repo_id=repo,
        filename="mmproj-DeepSeek-V4.1-Flash-1017-abliterated-BF16.gguf",
        local_dir=str(mmproj_tmp),
        token=token,
    )
    subprocess.run(
        [sys.executable, "/content/project-maya/tools/ds4/vision_pack.py", "--dir", str(vision_dir), "--mmproj", mmproj_path],
        check=True,
    )
    shutil.rmtree(mmproj_tmp, ignore_errors=True)
PY

rm -rf "$MODEL_ROOT/.cache" "${SCRATCH_SHARDS_DIR:-/tmp/nonexistent}/.cache" /tmp/hf-xet-cache 2>/dev/null || true

echo "[5/6] 恢复预打包索引与写入自适应配置..."
if [ -f "$WORK_DIR/pack-meta-256g.tar.gz" ]; then
  rm -rf "$MODEL_ROOT/Mix-256G/maya-ds4"
  tar -xzf "$WORK_DIR/pack-meta-256g.tar.gz" -C "$MODEL_ROOT/Mix-256G/"
fi

# 如果是不同 GPU，删掉旧 GPU 的 lane-times.txt 让启动时花 0.4 秒重新测一次当前 PCIe 通道耗时
if ! echo "$GPU_NAME" | grep -qi "Blackwell"; then
  rm -f "$MODEL_ROOT/Mix-256G/maya-ds4/lane-times.txt"
fi

export PREFILL_CHUNK RAM_MARGIN DISK_SKIP_W PROMPT_PICK ENGRAM_CACHE_MB LENT_RAM_GB FLOW_COPY_DMA ENGRAM_THREADS YOCO_CONE EG_RANDOM RESTORE_TAIL S2_LOCAL_MAX S2_GCS_THRESH S2_GCS_DISABLE INDEX_TC CPU_PREPARE_ROWS
"$WORK_DIR/.venv/bin/python" - << 'PY'
import json, os
cfg_path = "/content/project-maya/maya-ds4.json"
with open(cfg_path, "r") as f:
    cfg = json.load(f)
args = cfg.setdefault("args", [])
pchunk = os.environ.get("PREFILL_CHUNK") or "16384"
if "--prefill-chunk" in args:
    idx = args.index("--prefill-chunk")
    if idx + 1 < len(args):
        args[idx + 1] = pchunk
    else:
        args.append(pchunk)
else:
    args.extend(["--prefill-chunk", pchunk])

cfg.setdefault("env", {})
cfg["env"]["DS4_RAM_MARGIN_GB"] = os.environ["RAM_MARGIN"]
cfg["env"]["DS4_STAT_LOG"] = "1"
if float(os.environ["DISK_SKIP_W"]) > 0:
    cfg["env"]["MAYA_DS4_DISK_SKIP_W"] = os.environ["DISK_SKIP_W"]
else:
    cfg["env"].pop("MAYA_DS4_DISK_SKIP_W", None)

opt_map = {
    "PROMPT_PICK": "DS4_PROMPT_PICK",
    "ENGRAM_CACHE_MB": "DS4_ENGRAM_CACHE_MB",
    "LENT_RAM_GB": "DS4_LENT_RAM_GB",
    "FLOW_COPY_DMA": "DS4_FLOW_COPY_DMA",
    "ENGRAM_THREADS": "DS4_ENGRAM_THREADS",
    "YOCO_CONE": "DS4_YOCO_CONE",
    "EG_RANDOM": "MAYA_DS4_EG_RANDOM",
    "RESTORE_TAIL": "MAYA_DS4_RESTORE_TAIL",
    "S2_LOCAL_MAX": "MAYA_S2_LOCAL_MAX",
    "S2_GCS_THRESH": "MAYA_S2_GCS_THRESH",
    "S2_GCS_DISABLE": "MAYA_S2_GCS_DISABLE",
    "INDEX_TC": "DS4_INDEX_TC",
    "CPU_PREPARE_ROWS": "DS4_CPU_PREPARE_ROWS",
}
for src_k, dst_k in opt_map.items():
    val = os.environ.get(src_k, "").strip()
    if val:
        cfg["env"][dst_k] = val
    else:
        cfg["env"].pop(dst_k, None)

with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=1)
PY

echo "[6/6] 启动 maya.py 与 Cloudflare 隧道..."
"$WORK_DIR/.venv/bin/python" - "$WORK_DIR" << 'PY'
import os, signal, sys
wdir = sys.argv[1]
targets = (f"{wdir}/maya.py", f"{wdir}/serve/server.py", f"{wdir}/build/maya-ds4")
skip = {os.getpid(), os.getppid()}
for ent in os.listdir("/proc"):
    if not ent.isdigit():
        continue
    pid = int(ent)
    if pid in skip:
        continue
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except Exception:
        continue
    if not raw:
        continue
    argv = [a.decode("utf-8", "ignore") for a in raw.split(b"\x00") if a]
    if not argv:
        continue
    exe0 = os.path.basename(argv[0])
    if exe0 in ("bash", "sh", "dash", "zsh"):
        continue
    cmd = " ".join(argv)
    if any(t in cmd for t in targets):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY

PRELOAD_ENV=""
if [ -n "${REMOTE_MOUNT_DIR:-}" ]; then
  if ! command -v gcc >/dev/null 2>&1 || { [ ! -f /usr/include/x86_64-linux-gnu/curl/curl.h ] && [ ! -f /usr/include/curl/curl.h ]; }; then
    echo "  -> 安装 libcurl4-openssl-dev (用于 HTTP/2 直连旁路)..."
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc libcurl4-openssl-dev
  fi
  write_refresher_script
  "$WORK_DIR/maya_url_token_refresher.sh" --once || true
  if ! pgrep -f "maya_url_token_refresher.sh" >/dev/null 2>&1; then
    nohup "$WORK_DIR/maya_url_token_refresher.sh" >/dev/null 2>&1 < /dev/null &
  fi
  echo "  -> 编译 gcs_tls_pread.so (FUSE >256KB HF/GCS HTTP/2 直连旁路 + Shard 00002 mincore 双模态门控)..."
  if [ ! -f /tmp/gcs_tls_pread.c ]; then
    cat > /tmp/gcs_tls_pread.c << 'CEOF'
/*
 * gcs_tls_pread.c — LD_PRELOAD dual-regime GCS + NVMe I/O accelerator for Project Maya (maya-ds4)
 *
 * Build on Linux (Google Colab x86_64):
 *   gcc -Wall -Wextra -Werror -shared -fPIC -O2 -U_FORTIFY_SOURCE \
 *       src/gcs_tls_pread.c -o gcs_tls_pread.so -lcurl -ldl -lpthread
 *
 * Architecture:
 *   1. FUSE > 256 KB Direct HTTPS HTTP/2 Range Bypass (`fuse_direct_pread64`) +
 *      2 MB per-thread TLS metadata windows: eliminates gcsfuse's ~5.1x cold-load
 *      read amplification (~645 GB -> ~145 GB), cutting cold GCS load from ~49 min
 *      down to ~11.6-12.5 min.
 *   2. Shard 00002 (110.6 GiB Engram random-lookup table) 3-Tier Accelerator (`s2_pread64`):
 *      - Tier 1: Zero-syscall OS Page Cache hit via mincore() + memcpy() on MAP_SHARED mmap.
 *      - Tier 2 (MAYA_S2_GCS_THRESH=160): Decode & short-prompt gate keeps tot <= 160
 *        100% on local NVMe (0 network RTT stragglers, full OS Page Cache population).
 *      - Tier 3 (MAYA_S2_LOCAL_MAX=16 + 8x8 HTTP/2 curl_multi pool): Prefill bursts
 *        (DS4_ENGRAM_THREADS=768, tot > 160) cap local NVMe at QD=16 (~1,860 IOPS sweet spot)
 *        and spill overflow across 64 multiplexed TLS HTTP/2 streams on 50 Gbps gVNIC,
 *        with lossless real_pread64() fallback on timeout or gateway reconnect.
 *
 * Auth / Config Files Read at Runtime:
 *   - /dev/shm/.maya_hf_urls      (chmod 600 presigned HF CDN URL table: <rel_path>\t<size>\t<url>)
 *   - /tmp/gcs-bucket             (single line GCS bucket name)
 *   - /dev/shm/.maya_gcs_token    (chmod 600 OAuth2 access token refreshed by background daemon)
 */

#define _GNU_SOURCE
#include <curl/curl.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <time.h>
#include <unistd.h>

#define MAX_TRACKED_FD 8192
#define FUSE_SUPER_MAGIC 0x65735546UL
#define N_TLS_SLOTS 4
#define CACHE_WIN_SIZE (2 * 1024 * 1024)
#define CACHE_ADJ_GAP  (512 * 1024)
#define CACHE_SMALL_PAD 65536
#define FUSE_SMALL_MAX 262144
#define FD_KIND_NONE 0
#define FD_KIND_FUSE 1
#define FD_KIND_S2   2
#define S2_MAX_FAST_READ 8192
#define H2_SHARDS 8
#define H2_CONNS_PER_SHARD 8L
#define H2_MAX_ACTIVE_PER_SHARD 128
#define H2_MAX_FREE_HANDLES 160
#define TOKEN_PATH "/dev/shm/.maya_gcs_token"
#define BUCKET_PATH "/tmp/gcs-bucket"
#define HF_DEFAULT_MOUNT_PREFIX "/mnt/hf/"
#define HF_DEFAULT_URLS_PATH "/dev/shm/.maya_hf_urls"
#define HF_DEFAULT_REFRESHER "/content/project-maya/maya_url_token_refresher.sh --hf-only"
#define MAX_HF_DIRECT 16
#define HF_URL_MAX 8192
#define HF_URLS_BUF_MAX (256 * 1024)
#define S2_OBJ_REL "Mix-256G/DeepSeek-V4.1-Flash-1017-abliterated-Mix-256G-00002-of-00007.gguf"
#define S2_SUFFIX "-00002-of-00007.gguf"

static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_open64)(const char *, int, ...) = NULL;
static int (*real_openat)(int, const char *, int, ...) = NULL;
static int (*real_openat64)(int, const char *, int, ...) = NULL;
static int (*real_close)(int) = NULL;
static ssize_t (*real_pread64)(int, void *, size_t, off64_t) = NULL;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char *g_fd_path[MAX_TRACKED_FD];
static uint64_t g_fd_gen[MAX_TRACKED_FD];
static int g_fd_kind[MAX_TRACKED_FD];

/* Shard 00002 global mmap + stats + GCS config */
static pthread_mutex_t g_s2_init_lock = PTHREAD_MUTEX_INITIALIZER;
static void *g_s2_map = NULL;
static size_t g_s2_size = 0;
static int g_s2_local_max = 16;
static int g_s2_gcs_thresh = 160;
static int g_s2_total_inflight = 0;
static int g_s2_local_inflight = 0;
static int g_s2_gcs_disable = 0;
static int g_fuse_direct_disable = 0;
static int g_s2_debug = 0;
static uint32_t g_shard_rr = 0;

static pthread_once_t g_curl_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_gcs_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_gcs_cfg_loaded = 0;
static int g_gcs_enabled = 0;
static char g_gcs_bucket[512];
static char g_gcs_url[1024];
static char g_tok_hdr[2304];
static uint64_t g_tok_ver = 0;
static uint64_t g_tok_last_ns = 0;

struct HfDirectEntry {
    char rel_path[512];
    uint64_t size;
    char url[HF_URL_MAX];
};

static char g_hf_mount_prefix[PATH_MAX] = HF_DEFAULT_MOUNT_PREFIX;
static size_t g_hf_mount_prefix_len = 8;
static char g_hf_urls_path[PATH_MAX] = HF_DEFAULT_URLS_PATH;
static char g_hf_refresher_cmd[PATH_MAX] = HF_DEFAULT_REFRESHER;
static pthread_mutex_t g_hf_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_hf_refresh_lock = PTHREAD_MUTEX_INITIALIZER;
static struct HfDirectEntry g_hf_entries[MAX_HF_DIRECT];
static int g_hf_n_entries = 0;
static struct timespec g_hf_last_mtime;
static uint64_t g_hf_last_stat_ns = 0;
static uint64_t g_hf_last_refresh_ns = 0;

static uint64_t g_stat_pc = 0;
static uint64_t g_stat_local = 0;
static uint64_t g_stat_gcs = 0;
static uint64_t g_stat_fb = 0;

struct StreamSlot {
    int orig_fd;
    uint64_t gen;
    int tfd;
    unsigned char *buf;
    off64_t start;
    size_t len;
    uint64_t tick;
};

struct TlsState {
    uint64_t clock;
    struct StreamSlot slots[N_TLS_SLOTS];
    CURL *fuse_eh;
    int sync_init;
    uint32_t shard_id;
    pthread_mutex_t req_mu;
    pthread_cond_t req_cv;
    unsigned char rxbuf[S2_MAX_FAST_READ];
};

struct RetiredList {
    struct curl_slist *list;
    struct RetiredList *next;
};

struct H2Req {
    off64_t offset;
    size_t count;
    unsigned char *dst;
    size_t cap;
    size_t got;
    int overflow;
    int ok;
    int unauthorized;
    int done;
    pthread_mutex_t *mu;
    pthread_cond_t *cv;
    CURL *eh;
    char range[64];
    struct H2Req *next;
};

struct FuseDirectCtx {
    unsigned char *dst;
    size_t cap;
    size_t got;
    int overflow;
};

struct H2Shard {
    int idx;
    CURLM *cm;
    pthread_mutex_t q_mu;
    struct H2Req *q_head;
    struct H2Req *q_tail;
    CURL *free_eh[H2_MAX_FREE_HANDLES];
    int free_n;
    int active_cnt;
    uint64_t shard_tok_ver;
    struct curl_slist *cur_hdr;
    struct RetiredList *retired;
    int ready;
};

static struct H2Shard g_shards[H2_SHARDS];
static pthread_once_t g_h2_once = PTHREAD_ONCE_INIT;
static int g_h2_pool_ok = 0;

static pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;
static pthread_key_t g_tls_key;

static uint64_t mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

__attribute__((constructor))
static void init_syms(void) {
    real_open = dlsym(RTLD_NEXT, "open");
    real_open64 = dlsym(RTLD_NEXT, "open64");
    real_openat = dlsym(RTLD_NEXT, "openat");
    real_openat64 = dlsym(RTLD_NEXT, "openat64");
    real_close = dlsym(RTLD_NEXT, "close");
    real_pread64 = dlsym(RTLD_NEXT, "pread64");
    const char *lm = getenv("MAYA_S2_LOCAL_MAX");
    if (lm && lm[0]) {
        int v = atoi(lm);
        if (v >= 0 && v <= 1024) g_s2_local_max = v;
    }
    const char *gt = getenv("MAYA_S2_GCS_THRESH");
    if (gt && gt[0]) {
        int v = atoi(gt);
        if (v >= 0 && v <= 65536) g_s2_gcs_thresh = v;
    }
    const char *dis = getenv("MAYA_S2_GCS_DISABLE");
    if (dis && atoi(dis) != 0) g_s2_gcs_disable = 1;
    const char *fdd = getenv("MAYA_FUSE_DIRECT_DISABLE");
    if (fdd && atoi(fdd) != 0) g_fuse_direct_disable = 1;
    const char *dbg = getenv("MAYA_S2_DEBUG");
    if (dbg && atoi(dbg) != 0) g_s2_debug = 1;
    const char *hf_pref = getenv("MAYA_HF_MOUNT_PREFIX");
    if (hf_pref && hf_pref[0]) {
        snprintf(g_hf_mount_prefix, sizeof(g_hf_mount_prefix), "%s", hf_pref);
        size_t plen = strlen(g_hf_mount_prefix);
        if (plen > 0 && g_hf_mount_prefix[plen - 1] != '/' && plen + 1 < sizeof(g_hf_mount_prefix)) {
            g_hf_mount_prefix[plen++] = '/';
            g_hf_mount_prefix[plen] = '\0';
        }
        g_hf_mount_prefix_len = plen;
    }
    const char *hf_urls = getenv("MAYA_HF_URLS_PATH");
    if (hf_urls && hf_urls[0]) {
        snprintf(g_hf_urls_path, sizeof(g_hf_urls_path), "%s", hf_urls);
    }
    const char *hf_ref = getenv("MAYA_HF_REFRESHER");
    if (hf_ref) {
        snprintf(g_hf_refresher_cmd, sizeof(g_hf_refresher_cmd), "%s", hf_ref);
    }
}

__attribute__((destructor))
static void fini_stats(void) {
    if (g_s2_debug) {
        fprintf(stderr,
                "[gcs_tls_pread] s2 stats: pagecache=%llu local=%llu gcs=%llu fallback=%llu\n",
                (unsigned long long)__atomic_load_n(&g_stat_pc, __ATOMIC_RELAXED),
                (unsigned long long)__atomic_load_n(&g_stat_local, __ATOMIC_RELAXED),
                (unsigned long long)__atomic_load_n(&g_stat_gcs, __ATOMIC_RELAXED),
                (unsigned long long)__atomic_load_n(&g_stat_fb, __ATOMIC_RELAXED));
    }
}

static void init_curl_global(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

static size_t h2_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    size_t total = size * nmemb;
    struct H2Req *req = (struct H2Req *)userdata;
    if (total > req->cap - req->got) {
        req->overflow = 1;
        return 0;
    }
    memcpy(req->dst + req->got, ptr, total);
    req->got += total;
    return total;
}

static size_t fuse_direct_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    size_t total = size * nmemb;
    struct FuseDirectCtx *ctx = (struct FuseDirectCtx *)userdata;
    if (total > ctx->cap - ctx->got) {
        ctx->overflow = 1;
        return 0;
    }
    memcpy(ctx->dst + ctx->got, ptr, total);
    ctx->got += total;
    return total;
}

static int read_small_file_trimmed(const char *path, char *out, size_t out_sz) {
    if (!real_open || !real_close) return -1;
    int fd = real_open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t n = 0;
    while (n + 1 < out_sz) {
        ssize_t r = read(fd, out + n, out_sz - 1 - n);
        if (r < 0) {
            if (errno == EINTR) continue;
            real_close(fd);
            return -1;
        }
        if (r == 0) break;
        n += (size_t)r;
    }
    real_close(fd);
    out[n] = '\0';
    while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r' || out[n - 1] == ' ' || out[n - 1] == '\t')) {
        out[--n] = '\0';
    }
    return n > 0 ? 0 : -1;
}

static void refresh_gcs_state_locked(int force_tok) {
    if (!g_gcs_cfg_loaded) {
        char bucket[512];
        if (read_small_file_trimmed(BUCKET_PATH, bucket, sizeof(bucket)) == 0) {
            snprintf(g_gcs_bucket, sizeof(g_gcs_bucket), "%s", bucket);
        }
        if (!g_s2_gcs_disable) {
            const char *env_url = getenv("MAYA_S2_GCS_URL");
            if (env_url && env_url[0]) {
                snprintf(g_gcs_url, sizeof(g_gcs_url), "%s", env_url);
                g_gcs_enabled = 1;
            } else if (g_gcs_bucket[0]) {
                snprintf(g_gcs_url, sizeof(g_gcs_url),
                         "https://storage.googleapis.com/%s/%s", g_gcs_bucket, S2_OBJ_REL);
                g_gcs_enabled = 1;
            }
        }
        __atomic_store_n(&g_gcs_cfg_loaded, 1, __ATOMIC_RELEASE);
    }
    if (!g_gcs_enabled && !g_gcs_bucket[0]) return;
    uint64_t now = mono_ns();
    if (force_tok || g_tok_ver == 0 || (now - g_tok_last_ns) >= 30000000000ULL) {
        g_tok_last_ns = now;
        char tok[2048];
        if (read_small_file_trimmed(TOKEN_PATH, tok, sizeof(tok)) == 0) {
            char cand[2304];
            snprintf(cand, sizeof(cand), "Authorization: Bearer %s", tok);
            if (strcmp(cand, g_tok_hdr) != 0) {
                snprintf(g_tok_hdr, sizeof(g_tok_hdr), "%s", cand);
                __atomic_fetch_add(&g_tok_ver, 1, __ATOMIC_RELEASE);
            }
        }
    }
}

static int ensure_gcs_token(void) {
    if (!__atomic_load_n(&g_gcs_cfg_loaded, __ATOMIC_ACQUIRE)) {
        pthread_mutex_lock(&g_gcs_lock);
        refresh_gcs_state_locked(1);
        pthread_mutex_unlock(&g_gcs_lock);
    } else {
        uint64_t last = __atomic_load_n(&g_tok_last_ns, __ATOMIC_RELAXED);
        uint64_t now = mono_ns();
        uint64_t interval = (__atomic_load_n(&g_tok_ver, __ATOMIC_ACQUIRE) == 0)
                            ? 1000000000ULL : 30000000000ULL;
        if (now - last >= interval) {
            pthread_mutex_lock(&g_gcs_lock);
            refresh_gcs_state_locked(0);
            pthread_mutex_unlock(&g_gcs_lock);
        }
    }
    return __atomic_load_n(&g_tok_ver, __ATOMIC_ACQUIRE) > 0;
}

static int ensure_gcs_ready(void) {
    if (g_s2_gcs_disable) return 0;
    if (!ensure_gcs_token()) return 0;
    return __atomic_load_n(&g_gcs_enabled, __ATOMIC_ACQUIRE);
}

static void shard_sync_token(struct H2Shard *sh) {
    uint64_t gv = __atomic_load_n(&g_tok_ver, __ATOMIC_ACQUIRE);
    if (gv == sh->shard_tok_ver && sh->cur_hdr != NULL) return;
    char hdr_copy[2304];
    hdr_copy[0] = '\0';
    pthread_mutex_lock(&g_gcs_lock);
    gv = g_tok_ver;
    if (g_tok_hdr[0]) snprintf(hdr_copy, sizeof(hdr_copy), "%s", g_tok_hdr);
    pthread_mutex_unlock(&g_gcs_lock);
    if (!hdr_copy[0]) return;
    struct curl_slist *nl = curl_slist_append(NULL, hdr_copy);
    if (!nl) return;
    if (sh->cur_hdr) {
        struct RetiredList *r = (struct RetiredList *)malloc(sizeof(*r));
        if (r) {
            r->list = sh->cur_hdr;
            r->next = sh->retired;
            sh->retired = r;
        }
    }
    sh->cur_hdr = nl;
    sh->shard_tok_ver = gv;
}

static void shard_reap_retired(struct H2Shard *sh) {
    if (sh->active_cnt != 0 || !sh->retired) return;
    struct RetiredList *r = sh->retired;
    sh->retired = NULL;
    while (r) {
        struct RetiredList *nxt = r->next;
        curl_slist_free_all(r->list);
        free(r);
        r = nxt;
    }
}

static CURL *shard_acquire_handle(struct H2Shard *sh) {
    CURL *eh = NULL;
    if (sh->free_n > 0) {
        eh = sh->free_eh[--sh->free_n];
    } else {
        eh = curl_easy_init();
        if (!eh) return NULL;
        curl_easy_setopt(eh, CURLOPT_URL, g_gcs_url);
        curl_easy_setopt(eh, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(eh, CURLOPT_TCP_NODELAY, 1L);
        curl_easy_setopt(eh, CURLOPT_TCP_KEEPALIVE, 1L);
        curl_easy_setopt(eh, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS);
        curl_easy_setopt(eh, CURLOPT_PIPEWAIT, 1L);
        curl_easy_setopt(eh, CURLOPT_WRITEFUNCTION, h2_write_cb);
        curl_easy_setopt(eh, CURLOPT_CONNECTTIMEOUT_MS, 2500L);
        curl_easy_setopt(eh, CURLOPT_TIMEOUT_MS, 4000L);
        curl_easy_setopt(eh, CURLOPT_BUFFERSIZE, 16384L);
    }
    return eh;
}

static void *h2_shard_loop(void *arg) {
    struct H2Shard *sh = (struct H2Shard *)arg;
    for (;;) {
        int launched = 0;
        for (;;) {
            if (sh->active_cnt >= H2_MAX_ACTIVE_PER_SHARD) break;
            pthread_mutex_lock(&sh->q_mu);
            struct H2Req *req = sh->q_head;
            if (req) {
                sh->q_head = req->next;
                if (!sh->q_head) sh->q_tail = NULL;
            }
            pthread_mutex_unlock(&sh->q_mu);
            if (!req) break;
            req->next = NULL;

            shard_sync_token(sh);
            CURL *eh = shard_acquire_handle(sh);
            if (!eh || !sh->cur_hdr) {
                if (eh) {
                    if (sh->free_n < H2_MAX_FREE_HANDLES) sh->free_eh[sh->free_n++] = eh;
                    else curl_easy_cleanup(eh);
                }
                pthread_mutex_lock(req->mu);
                req->ok = 0;
                req->done = 1;
                pthread_cond_signal(req->cv);
                pthread_mutex_unlock(req->mu);
                continue;
            }
            req->eh = eh;
            snprintf(req->range, sizeof(req->range), "%llu-%llu",
                     (unsigned long long)req->offset,
                     (unsigned long long)(req->offset + (off64_t)req->count - 1));
            curl_easy_setopt(eh, CURLOPT_PRIVATE, req);
            curl_easy_setopt(eh, CURLOPT_HTTPHEADER, sh->cur_hdr);
            curl_easy_setopt(eh, CURLOPT_RANGE, req->range);
            curl_easy_setopt(eh, CURLOPT_WRITEDATA, req);
            CURLMcode mc = curl_multi_add_handle(sh->cm, eh);
            if (mc != CURLM_OK) {
                if (sh->free_n < H2_MAX_FREE_HANDLES) sh->free_eh[sh->free_n++] = eh;
                else curl_easy_cleanup(eh);
                pthread_mutex_lock(req->mu);
                req->ok = 0;
                req->done = 1;
                pthread_cond_signal(req->cv);
                pthread_mutex_unlock(req->mu);
                continue;
            }
            sh->active_cnt++;
            launched++;
        }

        int still = 0;
        if (sh->active_cnt > 0 || launched > 0) {
            curl_multi_perform(sh->cm, &still);
        }

        CURLMsg *msg;
        int msgs_left = 0;
        while ((msg = curl_multi_info_read(sh->cm, &msgs_left)) != NULL) {
            if (msg->msg == CURLMSG_DONE) {
                CURL *eh = msg->easy_handle;
                struct H2Req *req = NULL;
                curl_easy_getinfo(eh, CURLINFO_PRIVATE, &req);
                long code = 0;
                CURLcode res = msg->data.result;
                if (res == CURLE_OK) {
                    curl_easy_getinfo(eh, CURLINFO_RESPONSE_CODE, &code);
                }
                curl_multi_remove_handle(sh->cm, eh);
                sh->active_cnt--;
                if (sh->free_n < H2_MAX_FREE_HANDLES) sh->free_eh[sh->free_n++] = eh;
                else curl_easy_cleanup(eh);

                int ok = (res == CURLE_OK && code == 206 && !req->overflow && req->got == req->count);
                int unauth = (res == CURLE_OK && code == 401);
                pthread_mutex_lock(req->mu);
                req->ok = ok;
                req->unauthorized = unauth;
                req->done = 1;
                pthread_cond_signal(req->cv);
                pthread_mutex_unlock(req->mu);
            }
        }

        shard_reap_retired(sh);

        pthread_mutex_lock(&sh->q_mu);
        int q_has = (sh->q_head != NULL && sh->active_cnt < H2_MAX_ACTIVE_PER_SHARD);
        pthread_mutex_unlock(&sh->q_mu);
        if (q_has) continue;

        curl_multi_poll(sh->cm, NULL, 0, sh->active_cnt > 0 ? 50 : 200, NULL);
    }
    return NULL;
}

static void init_h2_pool(void) {
    pthread_once(&g_curl_once, init_curl_global);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int all_ok = 1;
    for (int i = 0; i < H2_SHARDS; i++) {
        struct H2Shard *sh = &g_shards[i];
        memset(sh, 0, sizeof(*sh));
        sh->idx = i;
        pthread_mutex_init(&sh->q_mu, NULL);
        sh->cm = curl_multi_init();
        if (!sh->cm) {
            all_ok = 0;
            continue;
        }
        curl_multi_setopt(sh->cm, CURLMOPT_PIPELINING, CURLPIPE_MULTIPLEX);
        curl_multi_setopt(sh->cm, CURLMOPT_MAX_HOST_CONNECTIONS, H2_CONNS_PER_SHARD);
        curl_multi_setopt(sh->cm, CURLMOPT_MAX_TOTAL_CONNECTIONS, H2_CONNS_PER_SHARD);
        pthread_t tid;
        if (pthread_create(&tid, &attr, h2_shard_loop, sh) == 0) {
            sh->ready = 1;
        } else {
            all_ok = 0;
        }
    }
    pthread_attr_destroy(&attr);
    __atomic_store_n(&g_h2_pool_ok, all_ok, __ATOMIC_RELEASE);
}

static void destroy_tls_state(void *ptr) {
    struct TlsState *st = (struct TlsState *)ptr;
    if (!st) return;
    for (int i = 0; i < N_TLS_SLOTS; i++) {
        if (st->slots[i].tfd >= 0) {
            if (real_close) real_close(st->slots[i].tfd);
            st->slots[i].tfd = -1;
        }
        if (st->slots[i].buf && st->slots[i].buf != MAP_FAILED) {
            munmap(st->slots[i].buf, CACHE_WIN_SIZE);
            st->slots[i].buf = NULL;
        }
    }
    if (st->fuse_eh) {
        curl_easy_cleanup(st->fuse_eh);
        st->fuse_eh = NULL;
    }
    if (st->sync_init) {
        pthread_cond_destroy(&st->req_cv);
        pthread_mutex_destroy(&st->req_mu);
    }
    free(st);
}

static void make_tls_key(void) {
    pthread_key_create(&g_tls_key, destroy_tls_state);
}

static struct TlsState *get_tls_state(void) {
    pthread_once(&g_tls_once, make_tls_key);
    struct TlsState *st = (struct TlsState *)pthread_getspecific(g_tls_key);
    if (!st) {
        st = (struct TlsState *)calloc(1, sizeof(*st));
        if (!st) return NULL;
        for (int i = 0; i < N_TLS_SLOTS; i++) {
            st->slots[i].orig_fd = -1;
            st->slots[i].tfd = -1;
        }
        pthread_mutex_init(&st->req_mu, NULL);
        pthread_cond_init(&st->req_cv, NULL);
        st->sync_init = 1;
        st->shard_id = __atomic_fetch_add(&g_shard_rr, 1, __ATOMIC_RELAXED) % H2_SHARDS;
        if (pthread_setspecific(g_tls_key, st) != 0) {
            destroy_tls_state(st);
            return NULL;
        }
    }
    return st;
}

static int ends_with(const char *s, const char *suffix) {
    if (!s || !suffix) return 0;
    size_t ls = strlen(s), lsf = strlen(suffix);
    return ls >= lsf && strcmp(s + (ls - lsf), suffix) == 0;
}

static void ensure_s2_mmap(int fd) {
    if (__atomic_load_n(&g_s2_map, __ATOMIC_ACQUIRE) != NULL) return;
    pthread_mutex_lock(&g_s2_init_lock);
    if (g_s2_map == NULL) {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > 0) {
            void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
            if (p != MAP_FAILED) {
                (void)madvise(p, (size_t)st.st_size, MADV_RANDOM);
                g_s2_size = (size_t)st.st_size;
                __atomic_store_n(&g_s2_map, p, __ATOMIC_RELEASE);
            }
        }
    }
    pthread_mutex_unlock(&g_s2_init_lock);
}

static void maybe_track(int fd, const char *path) {
    if (fd < 0 || fd >= MAX_TRACKED_FD || !path) return;
    struct statfs sfs;
    int is_fuse = (fstatfs(fd, &sfs) == 0 && (unsigned long)sfs.f_type == FUSE_SUPER_MAGIC);
    if (is_fuse) {
        char *resolved = realpath(path, NULL);
        if (!resolved) resolved = strdup(path);
        pthread_mutex_lock(&g_lock);
        free(g_fd_path[fd]);
        g_fd_path[fd] = resolved;
        __atomic_fetch_add(&g_fd_gen[fd], 1, __ATOMIC_RELEASE);
        __atomic_store_n(&g_fd_kind[fd], resolved ? FD_KIND_FUSE : FD_KIND_NONE, __ATOMIC_RELEASE);
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (ends_with(path, S2_SUFFIX)) {
        (void)posix_fadvise(fd, 0, 0, POSIX_FADV_RANDOM);
        ensure_s2_mmap(fd);
        pthread_mutex_lock(&g_lock);
        free(g_fd_path[fd]);
        g_fd_path[fd] = NULL;
        __atomic_fetch_add(&g_fd_gen[fd], 1, __ATOMIC_RELEASE);
        __atomic_store_n(&g_fd_kind[fd], FD_KIND_S2, __ATOMIC_RELEASE);
        pthread_mutex_unlock(&g_lock);
    }
}

int open(const char *pathname, int flags, ...) {
    if (!real_open) init_syms();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    int fd = (flags & O_CREAT) ? real_open(pathname, flags, mode) : real_open(pathname, flags);
    if (fd >= 0 && (flags & O_ACCMODE) == O_RDONLY && !(flags & O_DIRECTORY)) {
        maybe_track(fd, pathname);
    }
    return fd;
}

int open64(const char *pathname, int flags, ...) {
    if (!real_open64) init_syms();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    int fd = (flags & O_CREAT) ? real_open64(pathname, flags, mode) : real_open64(pathname, flags);
    if (fd >= 0 && (flags & O_ACCMODE) == O_RDONLY && !(flags & O_DIRECTORY)) {
        maybe_track(fd, pathname);
    }
    return fd;
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    if (!real_openat) init_syms();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    int fd = (flags & O_CREAT) ? real_openat(dirfd, pathname, flags, mode) : real_openat(dirfd, pathname, flags);
    if (fd >= 0 && (flags & O_ACCMODE) == O_RDONLY && !(flags & O_DIRECTORY) && pathname[0] == '/') {
        maybe_track(fd, pathname);
    }
    return fd;
}

int openat64(int dirfd, const char *pathname, int flags, ...) {
    if (!real_openat64) init_syms();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    int fd = (flags & O_CREAT) ? real_openat64(dirfd, pathname, flags, mode) : real_openat64(dirfd, pathname, flags);
    if (fd >= 0 && (flags & O_ACCMODE) == O_RDONLY && !(flags & O_DIRECTORY) && pathname[0] == '/') {
        maybe_track(fd, pathname);
    }
    return fd;
}

int __open_2(const char *pathname, int flags) {
    return open(pathname, flags);
}

int __open64_2(const char *pathname, int flags) {
    return open64(pathname, flags);
}

int close(int fd) {
    if (!real_close) init_syms();
    if (fd >= 0 && fd < MAX_TRACKED_FD && __atomic_load_n(&g_fd_kind[fd], __ATOMIC_ACQUIRE) != FD_KIND_NONE) {
        pthread_mutex_lock(&g_lock);
        __atomic_store_n(&g_fd_kind[fd], FD_KIND_NONE, __ATOMIC_RELEASE);
        __atomic_fetch_add(&g_fd_gen[fd], 1, __ATOMIC_RELEASE);
        free(g_fd_path[fd]);
        g_fd_path[fd] = NULL;
        pthread_mutex_unlock(&g_lock);
    }
    return real_close(fd);
}

static int s2_gcs_fetch(void *buf, size_t count, off64_t offset) {
    if (!ensure_gcs_ready()) return -1;
    pthread_once(&g_h2_once, init_h2_pool);
    if (!__atomic_load_n(&g_h2_pool_ok, __ATOMIC_ACQUIRE)) return -1;
    struct TlsState *st = get_tls_state();
    if (!st) return -1;
    struct H2Shard *sh = &g_shards[st->shard_id];
    if (!sh->ready) return -1;

    struct H2Req req;
    memset(&req, 0, sizeof(req));
    req.offset = offset;
    req.count = count;
    req.dst = st->rxbuf;
    req.cap = count;
    req.mu = &st->req_mu;
    req.cv = &st->req_cv;

    pthread_mutex_lock(&sh->q_mu);
    if (sh->q_tail) {
        sh->q_tail->next = &req;
        sh->q_tail = &req;
    } else {
        sh->q_head = &req;
        sh->q_tail = &req;
    }
    pthread_mutex_unlock(&sh->q_mu);
    curl_multi_wakeup(sh->cm);

    pthread_mutex_lock(&st->req_mu);
    while (!req.done) {
        pthread_cond_wait(&st->req_cv, &st->req_mu);
    }
    pthread_mutex_unlock(&st->req_mu);

    if (req.ok) {
        memcpy(buf, st->rxbuf, count);
        return 0;
    }
    if (req.unauthorized) {
        pthread_mutex_lock(&g_gcs_lock);
        refresh_gcs_state_locked(1);
        pthread_mutex_unlock(&g_gcs_lock);
    }
    return -1;
}

static ssize_t s2_pread64(int orig_fd, void *buf, size_t count, off64_t offset) {
    if (count == 0 || count > S2_MAX_FAST_READ) {
        return real_pread64(orig_fd, buf, count, offset);
    }
    /* Tier 1: zero-syscall Page Cache hit via mincore + memcpy */
    void *map = __atomic_load_n(&g_s2_map, __ATOMIC_ACQUIRE);
    size_t msz = g_s2_size;
    if (map != NULL && (uint64_t)offset + count <= (uint64_t)msz) {
        uint64_t off_u = (uint64_t)offset;
        uint64_t p_start = off_u & ~4095ULL;
        uint64_t p_end = (off_u + (uint64_t)count + 4095ULL) & ~4095ULL;
        size_t n_pages = (size_t)((p_end - p_start) >> 12);
        if (n_pages > 0 && n_pages <= 4) {
            unsigned char vec[4] = {0};
            if (mincore((char *)map + p_start, n_pages << 12, vec) == 0) {
                int all_in = 1;
                for (size_t i = 0; i < n_pages; i++) {
                    if ((vec[i] & 1) == 0) { all_in = 0; break; }
                }
                if (all_in) {
                    memcpy(buf, (const unsigned char *)map + off_u, count);
                    __atomic_fetch_add(&g_stat_pc, 1, __ATOMIC_RELAXED);
                    return (ssize_t)count;
                }
            }
        }
    }
    if (g_s2_gcs_disable) {
        ssize_t r = real_pread64(orig_fd, buf, count, offset);
        __atomic_fetch_add(&g_stat_local, 1, __ATOMIC_RELAXED);
        return r;
    }
    /* Dual-regime concurrency gate:
     * Decode & short prompts (tot <= MAYA_S2_GCS_THRESH) stay 100% on local NVMe
     * (zero GCS RTT stragglers, full OS Page Cache population);
     * Long prefill bursts (tot > MAYA_S2_GCS_THRESH, e.g. 768 threads) cap local NVMe
     * at MAYA_S2_LOCAL_MAX and spill the rest to the 64-conn HTTP/2 GCS pool. */
    int tot = __atomic_add_fetch(&g_s2_total_inflight, 1, __ATOMIC_ACQ_REL);
    int gcs_thresh = __atomic_load_n(&g_s2_gcs_thresh, __ATOMIC_RELAXED);
    int local_max = __atomic_load_n(&g_s2_local_max, __ATOMIC_RELAXED);

    if (tot <= gcs_thresh) {
        __atomic_add_fetch(&g_s2_local_inflight, 1, __ATOMIC_ACQ_REL);
        ssize_t r = real_pread64(orig_fd, buf, count, offset);
        __atomic_sub_fetch(&g_s2_local_inflight, 1, __ATOMIC_RELEASE);
        __atomic_sub_fetch(&g_s2_total_inflight, 1, __ATOMIC_RELEASE);
        __atomic_fetch_add(&g_stat_local, 1, __ATOMIC_RELAXED);
        return r;
    }

    int inf = __atomic_add_fetch(&g_s2_local_inflight, 1, __ATOMIC_ACQ_REL);
    if (inf <= local_max) {
        ssize_t r = real_pread64(orig_fd, buf, count, offset);
        __atomic_sub_fetch(&g_s2_local_inflight, 1, __ATOMIC_RELEASE);
        __atomic_sub_fetch(&g_s2_total_inflight, 1, __ATOMIC_RELEASE);
        __atomic_fetch_add(&g_stat_local, 1, __ATOMIC_RELAXED);
        return r;
    }
    __atomic_sub_fetch(&g_s2_local_inflight, 1, __ATOMIC_RELEASE);

    /* Tier 3: GCS 50Gbps HTTP/2 curl_multi multiplexed pool */
    if (s2_gcs_fetch(buf, count, offset) == 0) {
        __atomic_sub_fetch(&g_s2_total_inflight, 1, __ATOMIC_RELEASE);
        __atomic_fetch_add(&g_stat_gcs, 1, __ATOMIC_RELAXED);
        return (ssize_t)count;
    }

    /* Lossless fallback */
    ssize_t r = real_pread64(orig_fd, buf, count, offset);
    __atomic_sub_fetch(&g_s2_total_inflight, 1, __ATOMIC_RELEASE);
    __atomic_fetch_add(&g_stat_fb, 1, __ATOMIC_RELAXED);
    return r;
}

static int parse_hf_urls_buffer(char *raw, struct HfDirectEntry *out, int *out_n) {
    int count = 0;
    char *p = raw;
    while (p && *p) {
        char *eol = strchr(p, '\n');
        if (eol) *eol++ = '\0';
        size_t len = strlen(p);
        while (len > 0 && p[len - 1] == '\r') p[--len] = '\0';
        if (len > 0 && p[0] != '#') {
            char *t1 = strchr(p, '\t');
            char *t2 = t1 ? strchr(t1 + 1, '\t') : NULL;
            if (t1 && t2) {
                *t1 = '\0';
                *t2 = '\0';
                const char *rel = p;
                while (*rel == '/') rel++;
                const char *sz_str = t1 + 1;
                const char *url = t2 + 1;
                if (rel[0] && sz_str[0] && url[0] &&
                    strlen(rel) < sizeof(out[0].rel_path) &&
                    strlen(url) < sizeof(out[0].url)) {
                    char *endp = NULL;
                    errno = 0;
                    unsigned long long sz = strtoull(sz_str, &endp, 10);
                    if (errno == 0 && endp != sz_str && (!endp || *endp == '\0') && sz > 0) {
                        if (count < MAX_HF_DIRECT) {
                            struct HfDirectEntry *e = &out[count++];
                            memset(e, 0, sizeof(*e));
                            snprintf(e->rel_path, sizeof(e->rel_path), "%s", rel);
                            e->size = (uint64_t)sz;
                            snprintf(e->url, sizeof(e->url), "%s", url);
                        }
                    }
                }
            }
        }
        p = eol;
    }
    if (count <= 0) return -1;
    *out_n = count;
    return 0;
}

static int ensure_hf_urls(int force_refresh) {
    if (!real_open || !real_close) return 0;
    if (force_refresh && g_hf_refresher_cmd[0]) {
        pthread_mutex_lock(&g_hf_refresh_lock);
        uint64_t now_r = mono_ns();
        if (now_r - g_hf_last_refresh_ns >= 5000000000ULL) {
            int rc = system(g_hf_refresher_cmd);
            (void)rc;
            g_hf_last_refresh_ns = mono_ns();
        }
        pthread_mutex_unlock(&g_hf_refresh_lock);
    }

    uint64_t now = mono_ns();
    pthread_mutex_lock(&g_hf_lock);
    int need_check = force_refresh || (g_hf_n_entries == 0) || ((now - g_hf_last_stat_ns) >= 5000000000ULL);
    if (need_check) {
        g_hf_last_stat_ns = now;
        struct stat st;
        if (stat(g_hf_urls_path, &st) == 0) {
            int mtime_changed = (st.st_mtim.tv_sec != g_hf_last_mtime.tv_sec ||
                                 st.st_mtim.tv_nsec != g_hf_last_mtime.tv_nsec);
            if (force_refresh || g_hf_n_entries == 0 || mtime_changed) {
                int fd = real_open(g_hf_urls_path, O_RDONLY | O_CLOEXEC);
                if (fd >= 0) {
                    char *raw = (char *)malloc(HF_URLS_BUF_MAX);
                    if (raw) {
                        size_t n = 0;
                        while (n + 1 < HF_URLS_BUF_MAX) {
                            ssize_t r = read(fd, raw + n, HF_URLS_BUF_MAX - 1 - n);
                            if (r < 0) {
                                if (errno == EINTR) continue;
                                break;
                            }
                            if (r == 0) break;
                            n += (size_t)r;
                        }
                        raw[n] = '\0';
                        struct HfDirectEntry tmp[MAX_HF_DIRECT];
                        int tmp_n = 0;
                        if (n > 0 && parse_hf_urls_buffer(raw, tmp, &tmp_n) == 0) {
                            memcpy(g_hf_entries, tmp, (size_t)tmp_n * sizeof(tmp[0]));
                            g_hf_n_entries = tmp_n;
                            g_hf_last_mtime = st.st_mtim;
                        }
                        free(raw);
                    }
                    real_close(fd);
                }
            }
        }
    }
    int ok = (g_hf_n_entries > 0);
    pthread_mutex_unlock(&g_hf_lock);
    return ok;
}

static int lookup_hf_direct(const char *rel_path, char *url_out, size_t url_cap,
                            uint64_t *size_out, int force_refresh) {
    if (!ensure_hf_urls(force_refresh)) return -1;
    pthread_mutex_lock(&g_hf_lock);
    for (int i = 0; i < g_hf_n_entries; i++) {
        if (strcmp(g_hf_entries[i].rel_path, rel_path) == 0) {
            snprintf(url_out, url_cap, "%s", g_hf_entries[i].url);
            *size_out = g_hf_entries[i].size;
            pthread_mutex_unlock(&g_hf_lock);
            return 0;
        }
    }
    pthread_mutex_unlock(&g_hf_lock);
    return -1;
}

static CURL *ensure_fuse_curl(struct TlsState *st) {
    pthread_once(&g_curl_once, init_curl_global);
    if (!st->fuse_eh) {
        st->fuse_eh = curl_easy_init();
        if (!st->fuse_eh) return NULL;
        curl_easy_setopt(st->fuse_eh, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(st->fuse_eh, CURLOPT_TCP_NODELAY, 1L);
        curl_easy_setopt(st->fuse_eh, CURLOPT_TCP_KEEPALIVE, 1L);
        curl_easy_setopt(st->fuse_eh, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS);
        curl_easy_setopt(st->fuse_eh, CURLOPT_CONNECTTIMEOUT_MS, 5000L);
        curl_easy_setopt(st->fuse_eh, CURLOPT_TIMEOUT_MS, 60000L);
        curl_easy_setopt(st->fuse_eh, CURLOPT_BUFFERSIZE, 524288L);
        curl_easy_setopt(st->fuse_eh, CURLOPT_WRITEFUNCTION, fuse_direct_write_cb);
    }
    return st->fuse_eh;
}

static ssize_t fuse_direct_pread64(struct TlsState *st, const char *path_buf,
                                   void *buf, size_t count, off64_t offset) {
    if (g_fuse_direct_disable) return -1;
    if (count == 0) return 0;

    if (strncmp(path_buf, g_hf_mount_prefix, g_hf_mount_prefix_len) == 0 &&
        path_buf[g_hf_mount_prefix_len] != '\0') {
        const char *rel = path_buf + g_hf_mount_prefix_len;
        char url[HF_URL_MAX];
        uint64_t fsize = 0;
        if (lookup_hf_direct(rel, url, sizeof(url), &fsize, 0) != 0) return -1;
        if ((uint64_t)offset >= fsize) return 0;

        size_t want = count;
        uint64_t remain = fsize - (uint64_t)offset;
        if ((uint64_t)want > remain) want = (size_t)remain;
        if (want == 0) return 0;

        CURL *eh = ensure_fuse_curl(st);
        if (!eh) return -1;

        char range[64];
        snprintf(range, sizeof(range), "%llu-%llu",
                 (unsigned long long)offset,
                 (unsigned long long)((uint64_t)offset + (uint64_t)want - 1ULL));

        for (int attempt = 0; attempt < 2; attempt++) {
            struct FuseDirectCtx ctx;
            ctx.dst = (unsigned char *)buf;
            ctx.cap = want;
            ctx.got = 0;
            ctx.overflow = 0;

            curl_easy_setopt(eh, CURLOPT_URL, url);
            curl_easy_setopt(eh, CURLOPT_HTTPHEADER, NULL);
            curl_easy_setopt(eh, CURLOPT_FOLLOWLOCATION, 1L);
            curl_easy_setopt(eh, CURLOPT_RANGE, range);
            curl_easy_setopt(eh, CURLOPT_WRITEDATA, &ctx);

            CURLcode res = curl_easy_perform(eh);
            long code = 0;
            if (res == CURLE_OK) {
                curl_easy_getinfo(eh, CURLINFO_RESPONSE_CODE, &code);
            }
            if (res == CURLE_OK && code == 206 && !ctx.overflow && ctx.got == want) {
                return (ssize_t)want;
            }
            if (attempt == 0 && res == CURLE_OK && (code == 401 || code == 403)) {
                if (lookup_hf_direct(rel, url, sizeof(url), &fsize, 1) == 0) continue;
            }
            break;
        }
        return -1;
    }

    if (strncmp(path_buf, "/mnt/gcs/", 9) != 0 || path_buf[9] == '\0') return -1;
    if (!ensure_gcs_token()) return -1;

    char bucket_copy[512];
    char tok_copy[2304];
    pthread_mutex_lock(&g_gcs_lock);
    snprintf(bucket_copy, sizeof(bucket_copy), "%s", g_gcs_bucket);
    snprintf(tok_copy, sizeof(tok_copy), "%s", g_tok_hdr);
    pthread_mutex_unlock(&g_gcs_lock);
    if (!bucket_copy[0] || !tok_copy[0]) return -1;

    CURL *eh = ensure_fuse_curl(st);
    if (!eh) return -1;

    char url[PATH_MAX + 600];
    snprintf(url, sizeof(url), "https://storage.googleapis.com/%s/%s", bucket_copy, path_buf + 9);
    char range[64];
    snprintf(range, sizeof(range), "%llu-%llu",
             (unsigned long long)offset,
             (unsigned long long)(offset + (off64_t)count - 1));

    for (int attempt = 0; attempt < 2; attempt++) {
        struct FuseDirectCtx ctx;
        ctx.dst = (unsigned char *)buf;
        ctx.cap = count;
        ctx.got = 0;
        ctx.overflow = 0;

        struct curl_slist *hdrs = curl_slist_append(NULL, tok_copy);
        if (!hdrs) return -1;
        curl_easy_setopt(eh, CURLOPT_URL, url);
        curl_easy_setopt(eh, CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(eh, CURLOPT_HTTPHEADER, hdrs);
        curl_easy_setopt(eh, CURLOPT_RANGE, range);
        curl_easy_setopt(eh, CURLOPT_WRITEDATA, &ctx);

        CURLcode res = curl_easy_perform(eh);
        curl_easy_setopt(eh, CURLOPT_HTTPHEADER, NULL);
        curl_slist_free_all(hdrs);

        long code = 0;
        if (res == CURLE_OK) {
            curl_easy_getinfo(eh, CURLINFO_RESPONSE_CODE, &code);
        }
        if (res == CURLE_OK && code == 206 && !ctx.overflow && ctx.got == count) {
            return (ssize_t)count;
        }
        if (res == CURLE_OK && code == 401 && attempt == 0) {
            pthread_mutex_lock(&g_gcs_lock);
            refresh_gcs_state_locked(1);
            snprintf(tok_copy, sizeof(tok_copy), "%s", g_tok_hdr);
            pthread_mutex_unlock(&g_gcs_lock);
            if (tok_copy[0]) continue;
        }
        break;
    }
    return -1;
}

static ssize_t cached_pread64(int orig_fd, void *buf, size_t count, off64_t offset) {
    if (!real_pread64) init_syms();
    if (orig_fd < 0 || orig_fd >= MAX_TRACKED_FD || offset < 0) {
        return real_pread64(orig_fd, buf, count, offset);
    }
    int kind = __atomic_load_n(&g_fd_kind[orig_fd], __ATOMIC_ACQUIRE);
    if (kind == FD_KIND_NONE) {
        return real_pread64(orig_fd, buf, count, offset);
    }
    if (kind == FD_KIND_S2) {
        return s2_pread64(orig_fd, buf, count, offset);
    }
    uint64_t cur_gen = __atomic_load_n(&g_fd_gen[orig_fd], __ATOMIC_ACQUIRE);
    struct TlsState *st = get_tls_state();
    if (!st) return real_pread64(orig_fd, buf, count, offset);

    if (count == 0) return real_pread64(orig_fd, buf, count, offset);
    if (count > FUSE_SMALL_MAX) {
        char path_buf[PATH_MAX];
        path_buf[0] = '\0';
        pthread_mutex_lock(&g_lock);
        if (g_fd_kind[orig_fd] == FD_KIND_FUSE && g_fd_gen[orig_fd] == cur_gen && g_fd_path[orig_fd]) {
            snprintf(path_buf, sizeof(path_buf), "%s", g_fd_path[orig_fd]);
        }
        pthread_mutex_unlock(&g_lock);
        if (path_buf[0]) {
            ssize_t dr = fuse_direct_pread64(st, path_buf, buf, count, offset);
            if (dr >= 0) return dr;
        }
        return real_pread64(orig_fd, buf, count, offset);
    }

    for (int i = 0; i < N_TLS_SLOTS; i++) {
        struct StreamSlot *sl = &st->slots[i];
        if (sl->orig_fd == orig_fd && sl->gen == cur_gen && sl->buf && sl->len > 0 && offset >= sl->start) {
            uint64_t rel = (uint64_t)(offset - sl->start);
            if (rel < (uint64_t)sl->len && count <= (size_t)((uint64_t)sl->len - rel)) {
                sl->tick = ++st->clock;
                memcpy(buf, sl->buf + rel, count);
                return (ssize_t)count;
            }
        }
    }

    int pick = -1;
    for (int i = 0; i < N_TLS_SLOTS; i++) {
        struct StreamSlot *sl = &st->slots[i];
        if (sl->orig_fd == orig_fd && sl->gen == cur_gen && sl->tfd >= 0 &&
            offset >= sl->start &&
            (uint64_t)(offset - sl->start) <= (uint64_t)sl->len + CACHE_ADJ_GAP) {
            pick = i;
            break;
        }
    }
    if (pick < 0) {
        for (int i = 0; i < N_TLS_SLOTS; i++) {
            struct StreamSlot *sl = &st->slots[i];
            if (sl->orig_fd < 0 || sl->orig_fd >= MAX_TRACKED_FD ||
                __atomic_load_n(&g_fd_kind[sl->orig_fd], __ATOMIC_ACQUIRE) != FD_KIND_FUSE ||
                sl->gen != __atomic_load_n(&g_fd_gen[sl->orig_fd], __ATOMIC_ACQUIRE)) {
                pick = i;
                break;
            }
        }
    }
    if (pick < 0) {
        pick = 0;
        for (int i = 1; i < N_TLS_SLOTS; i++) {
            if (st->slots[i].tick < st->slots[pick].tick) pick = i;
        }
    }

    struct StreamSlot *sl = &st->slots[pick];
    if (sl->orig_fd != orig_fd || sl->gen != cur_gen || sl->tfd < 0) {
        if (sl->tfd >= 0) {
            real_close(sl->tfd);
            sl->tfd = -1;
        }
        sl->orig_fd = -1;
        sl->len = 0;
        char path_buf[PATH_MAX];
        path_buf[0] = 0;
        pthread_mutex_lock(&g_lock);
        if (g_fd_kind[orig_fd] == FD_KIND_FUSE && g_fd_gen[orig_fd] == cur_gen && g_fd_path[orig_fd]) {
            snprintf(path_buf, sizeof(path_buf), "%s", g_fd_path[orig_fd]);
        }
        pthread_mutex_unlock(&g_lock);
        if (!path_buf[0]) return real_pread64(orig_fd, buf, count, offset);
        int nfd = real_open(path_buf, O_RDONLY);
        if (nfd < 0) return real_pread64(orig_fd, buf, count, offset);
        sl->orig_fd = orig_fd;
        sl->gen = cur_gen;
        sl->tfd = nfd;
    }

    if (!sl->buf) {
        void *p = mmap(NULL, CACHE_WIN_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            sl->tick = ++st->clock;
            return real_pread64(sl->tfd, buf, count, offset);
        }
        sl->buf = (unsigned char *)p;
    }

    off64_t win_start = (offset > CACHE_SMALL_PAD) ? ((offset - CACHE_SMALL_PAD) & ~(off64_t)4095) : 0;
    size_t total = 0;
    {
        char path_buf[PATH_MAX];
        path_buf[0] = '\0';
        pthread_mutex_lock(&g_lock);
        if (g_fd_kind[orig_fd] == FD_KIND_FUSE && g_fd_gen[orig_fd] == cur_gen && g_fd_path[orig_fd]) {
            snprintf(path_buf, sizeof(path_buf), "%s", g_fd_path[orig_fd]);
        }
        pthread_mutex_unlock(&g_lock);
        if (path_buf[0]) {
            ssize_t dr = fuse_direct_pread64(st, path_buf, sl->buf, CACHE_WIN_SIZE, win_start);
            if (dr > 0) total = (size_t)dr;
        }
    }
    if (total == 0) {
        while (total < CACHE_WIN_SIZE) {
            ssize_t r = real_pread64(sl->tfd, sl->buf + total, CACHE_WIN_SIZE - total, win_start + (off64_t)total);
            if (r < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (r == 0) break;
            total += (size_t)r;
        }
    }
    if (total == 0) {
        sl->len = 0;
        return real_pread64(sl->tfd, buf, count, offset);
    }
    sl->start = win_start;
    sl->len = total;
    sl->tick = ++st->clock;
    if (offset >= win_start && (uint64_t)(offset - win_start) < (uint64_t)total) {
        uint64_t rel = (uint64_t)(offset - win_start);
        size_t avail = total - (size_t)rel;
        size_t copy_n = (count < avail) ? count : avail;
        memcpy(buf, sl->buf + rel, copy_n);
        return (ssize_t)copy_n;
    }
    return real_pread64(sl->tfd, buf, count, offset);
}

ssize_t pread(int fd, void *buf, size_t count, off_t offset) {
    return cached_pread64(fd, buf, count, (off64_t)offset);
}

ssize_t pread64(int fd, void *buf, size_t count, off64_t offset) {
    return cached_pread64(fd, buf, count, offset);
}

ssize_t __pread_chk(int fd, void *buf, size_t nbytes, off_t offset, size_t buflen) {
    (void)buflen;
    return cached_pread64(fd, buf, nbytes, (off64_t)offset);
}

ssize_t __pread64_chk(int fd, void *buf, size_t nbytes, off64_t offset, size_t buflen) {
    (void)buflen;
    return cached_pread64(fd, buf, nbytes, offset);
}
CEOF
  fi
  gcc -Wall -Wextra -Werror -shared -fPIC -O2 -U_FORTIFY_SOURCE /tmp/gcs_tls_pread.c -o "$WORK_DIR/gcs_tls_pread.so.tmp" -lcurl -ldl -lpthread
  mv -f "$WORK_DIR/gcs_tls_pread.so.tmp" "$WORK_DIR/gcs_tls_pread.so"
  rm -f /tmp/gcs_tls_pread.c /tmp/hf_ro_fuse.c
  PRELOAD_ENV="LD_PRELOAD=$WORK_DIR/gcs_tls_pread.so MAYA_HF_MOUNT_PREFIX=/mnt/hf/ MAYA_HF_URLS_PATH=/dev/shm/.maya_hf_urls"
fi

: > "$WORK_DIR/maya-ds4.log"
env $PRELOAD_ENV MAYA_SH=1 nohup "$WORK_DIR/.venv/bin/python" "$WORK_DIR/maya.py" --config "$WORK_DIR/maya-ds4.json" --port 8000 --plain > "$WORK_DIR/maya-console.log" 2>&1 < /dev/null &
if ! pgrep -f "cloudflared.*8000" >/dev/null 2>&1; then
  nohup /usr/local/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8000 > "$WORK_DIR/cloudflared.log" 2>&1 < /dev/null &
fi

sleep 5
grep -h -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$WORK_DIR/cloudflared.log" /tmp/cloudflared.log 2>/dev/null | tail -n 1 || true
echo "启动已提交！查看加载进度: tail -f /content/project-maya/maya-ds4.log"
