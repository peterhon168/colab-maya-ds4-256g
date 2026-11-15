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
