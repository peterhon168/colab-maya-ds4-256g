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
