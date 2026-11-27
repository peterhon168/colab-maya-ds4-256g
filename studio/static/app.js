(() => {
  "use strict";

  const DEFAULT_MODES = [
    {
      id: "b1_pure_hf",
      title_zh: "Mode B1-Pure · 纯 HF 零云存储",
      title_en: "Mode B1-Pure · Pure HF Zero-GCS",
      desc_zh: "MAYA_S2_GCS_DISABLE=1，仅需 HF Token，零云存储月租与零 GCS 流量费",
      desc_en: "S2_GCS_DISABLE=1, HF Token only, zero GCS storage or egress fee",
      recommended: true,
    },
    {
      id: "b1_hf_fuse",
      title_zh: "Mode B1 · 同区 GCS 突发加速 (可选)",
      title_en: "Mode B1 · Optional Same-Region GCS",
      desc_zh: "HF Xet + /mnt/hf FUSE3；仅单区域同区桶时启用 >160 GCS 突发（勿用多区域桶）",
      desc_en: "HF Xet + /mnt/hf FUSE3; optional same single-region GCS >160 burst",
      recommended: false,
    },
    {
      id: "a_dual_disk",
      title_zh: "Mode A · A100 双盘直读",
      title_en: "Mode A · A100 Dual-Disk",
      desc_zh: "A100 /mnt/local-scratch 零挂盘配置",
      desc_en: "A100 /mnt/local-scratch direct shard layout",
      recommended: false,
    },
    {
      id: "b1_gcs",
      title_zh: "Mode B1-GCS · 传统 GCS 桶回落",
      title_en: "Mode B1-GCS · Legacy gcsfuse",
      desc_zh: "强制从 /mnt/gcs gcsfuse 拉取分片 5~7",
      desc_en: "Force shards 5~7 from /mnt/gcs gcsfuse",
      recommended: false,
    },
    {
      id: "b2_shm",
      title_zh: "Mode B2 · /dev/shm 内存盘兜底",
      title_en: "Mode B2 · /dev/shm RAMDisk Fallback",
      desc_zh: "110GB 内存盘缓存，无 /mnt/local-scratch 兜底",
      desc_en: "110GB /dev/shm cache without /mnt/local-scratch",
      recommended: false,
    },
  ];

  const DEPLOY_STEPS = [
    { step: 1, zh: "分配 GPU", en: "Provision GPU", sub_zh: "校验机型与会话 (~10–30s)", sub_en: "GPU shape (~10–30s)" },
    { step: 2, zh: "上传运行包", en: "Upload Runtime", sub_zh: "推送包与凭据 (~15–30s)", sub_en: "Upload bundle (~15–30s)" },
    { step: 3, zh: "HF Xet 拉取分片", en: "Pull NVMe Shards", sub_zh: "NVMe 分片+FUSE3 (~8–11m)", sub_en: "Shards + FUSE3 (~8–11m)" },
    { step: 4, zh: "编译与启动服务", en: "Compile & Boot", sub_zh: "编译预读库与拉起 (~15–30s)", sub_en: "Compile & boot (~15–30s)" },
    { step: 5, zh: "建立隧道", en: "Start Tunnel", sub_zh: "cloudflared 隧道 (~5–10s)", sub_en: "Tunnel URL (~5–10s)" },
    { step: 6, zh: "权重装入显存/内存", en: "Load Weights & Sync", sub_zh: "VRAM+RAM 专家装载 (~12–18m)", sub_en: "VRAM+RAM load (~12–18m)" },
  ];

  const I18N = {
    zh: {
      "status.online": "在线 · Ready",
      "status.loading": "加载/部署中",
      "status.standby": "待机未连接",
      "top.guide": "示例接入指南",
      "top.openExternal": "外部浏览器打开 WebUI",
      "top.privacyMask": "录屏隐私打码",
      "common.refresh": "刷新",
      "common.recommended": "推荐",
      "common.off": "未开启",
      "common.on": "运行中",
      "common.manage": "配置 ▸",
      "common.copy": "复制",
      "common.open": "打开",
      "common.cancel": "取消",
      "common.gotIt": "我知道了",
      "colab.title": "Colab 算力实例 & 额度",
      "colab.disconnected": "未连接",
      "colab.connected": "在线",
      "colab.googleAccount": "Google 账号",
      "colab.notLoggedIn": "未登录 Google 账号",
      "colab.switchAccount": "换号 / 登录",
      "colab.gpuLabel": "算力机型",
      "colab.g4Hint": "G4 不传 high-mem",
      "colab.g4Note": "Standard 单规格 (176.9GB RAM) · 不传 high-mem",
      "colab.a100Note": "双盘架构 · 自动启用 --high-mem",
      "colab.sessionName": "会话名称",
      "colab.deployBtn": "唤醒实例并部署",
      "colab.attachBtn": "无损纳管已运行会话",
      "colab.attachNote": "只读探测 GPU、进程与隧道 URL，绝不中断当前推理或保活任务。",
      "colab.balance": "账户余额 (CU)",
      "colab.burnRate": "扣费速率 (CU/h)",
      "colab.keepalive": "12m 保活",
      "colab.stopBtn": "释放云端实例",
      "engine.title": "推理引擎与加速模式",
      "engine.advancedOptions": "高级选项 (HF Repo / 上下文 / 双模阈值)",
      "engine.contextLimit": "上下文配置",
      "engine.visionLabel": "视觉多模态",
      "engine.saveMayaConfig": "保存 Maya 配置",
      "strata.callout": "支持直连远端或局域网 Strata 节点（兼容 /health、/status、/metrics 与 /v1/*），也支持在 Colab 通过 --engine strata 启动并挂载。",
      "strata.urlLabel": "Strata 节点地址 (Upstream URL)",
      "strata.modelLabel": "模型 ID",
      "strata.maxCtxLabel": "最大上下文",
      "strata.apiKeyLabel": "可选 API Key",
      "strata.connectBtn": "一键直连并挂载 Strata",
      "cred.stripTitle": "外部凭据状态 (~/.config/maya-gcs/)",
      "tabs.console": "原生 WebUI 控制台",
      "tabs.telemetry": "实时遥测与对话探针",
      "tabs.clients": "客户端一键接入",
      "stage.upstream": "上游",
      "stage.localProxy": "网关",
      "stage.reloadEmbed": "刷新内嵌页",
      "stage.syncPi": "一键同步至 Pi",
      "stage.iframeLoading": "正在加载内嵌界面...",
      "stage.fallbackOpen": "若外部页阻止嵌入可新窗口打开 ↗",
      "deploy.pipelineTitle": "云端推理引擎部署流水线",
      "deploy.idleSummary": "当前未连接到在线引擎。你可以启动全新 Colab 部署、无损纳管运行中的实例，或接入局域网/远端 Strata 节点。",
      "deploy.quickAttachTitle": "已有运行中的 easycolab 实例？",
      "deploy.quickAttachDesc": "使用只读无损纳管探测 GPU、/mnt/hf 挂载与 Cloudflare 隧道并立即挂载至本地 127.0.0.1:18766，完全不打断现有服务与保活守护。",
      "deploy.quickAttachBtn": "一键无损纳管 easycolab",
      "deploy.quickStrataBtn": "配置 Strata 直连",
      "telemetry.prefillSub": "最近一次提示词吞吐",
      "telemetry.decodeSub": "最近一次稳态生成",
      "telemetry.vramHit": "VRAM 命中率",
      "telemetry.vramSub": "热点专家显存驻留",
      "telemetry.totalReq": "总请求数",
      "telemetry.totalReqSub": "累计服务推理次数",
      "telemetry.queue": "活跃队列",
      "telemetry.idle": "空闲待命中",
      "telemetry.busy": "正在推理",
      "telemetry.recentRequests": "最近请求摘要",
      "table.time": "时间 / ID",
      "table.tokens": "Tokens (In / Out)",
      "table.status": "状态",
      "table.empty": "暂无最近请求遥测记录",
      "probe.title": "精简对话探针 (/v1/chat/completions)",
      "probe.maxTokens": "max_tokens",
      "probe.sendBtn": "发送探针测试",
      "clients.piTitle": "Pi & pi-web 自动同步",
      "clients.piDesc": "自动写入 $HOME/.pi/agent/models.json 并刷新本地 pi-web (127.0.0.1:30141)，推荐优先绑定本地同源网关 http://127.0.0.1:18766/v1。",
      "clients.useLocalProxy": "使用本地代理 (推荐)",
      "clients.syncNow": "立即同步至 Pi",
      "clients.syncIdle": "点击上方按钮可将当前活跃模型与 Base URL 写入本地 Pi 客户端配置。",
      "logs.title": "底层命令与实时日志",
      "logs.connecting": "连接中",
      "logs.live": "实时流",
      "logs.reconnecting": "重连中",
      "logs.catAll": "全部",
      "logs.catDeploy": "部署",
      "logs.catColab": "Colab",
      "logs.catKeepalive": "保活",
      "logs.catCmd": "命令",
      "logs.autoScroll": "滚底",
      "logs.clear": "清空",
      "logs.quickDiag": "快捷安全诊断",
      "logs.runCmd": "运行",
      "modal.authTitle": "Google Colab OAuth 账号授权",
      "modal.authDesc": "获取 Google OAuth 授权链接并在浏览器完成登录，然后将重定向地址或授权码 (Code) 粘贴到下方提交。",
      "modal.authUrlLabel": "步骤 1：获取并打开授权链接",
      "modal.genAuthUrl": "生成授权链接",
      "modal.authCodeLabel": "步骤 2：粘贴授权码或回调 URL",
      "modal.logoutBtn": "退出当前账号",
      "modal.submitAuth": "提交授权",
      "modal.stopTitle": "确认释放云端 Colab 实例？",
      "modal.stopWarn": "⚠️ 此操作不可撤销：未持久化的内存状态和临时容器数据将会被回收。请确认后再继续。",
      "modal.confirmStop": "确认释放实例",
      "modal.credTitle": "外部安全凭据设置 (~/.config/maya-gcs/)",
      "modal.credSecurityNote": "所有凭据仅以目录 0700 / 文件 0600 权限存储在本地 ~/.config/maya-gcs/，绝不会提交至仓库或暴露明文回显。留空项将保持原有文件不变。",
      "modal.pickJsonFile": "导入本地 .json",
      "modal.mayaKeyLabel": "Maya 公网网关密钥 (maya-api-key)",
      "modal.genMayaKey": "🎲 随机生成",
      "modal.clearKey": "清空密钥",
      "modal.saveCreds": "安全保存凭据",
      "modal.guideTitle": "Maya · Strata Studio 快速接入指南",
    },
    en: {
      "status.online": "Online · Ready",
      "status.loading": "Booting / Deploying",
      "status.standby": "Standby",
      "top.guide": "Quick Guide",
      "top.openExternal": "Open WebUI in Browser",
      "top.privacyMask": "Privacy Mask",
      "common.refresh": "Refresh",
      "common.recommended": "Recommended",
      "common.off": "Off",
      "common.on": "Active",
      "common.manage": "Manage ▸",
      "common.copy": "Copy",
      "common.open": "Open",
      "common.cancel": "Cancel",
      "common.gotIt": "Got it",
      "colab.title": "Colab Compute & Quota",
      "colab.disconnected": "Standby",
      "colab.connected": "Online",
      "colab.googleAccount": "Google Account",
      "colab.notLoggedIn": "Not signed in",
      "colab.switchAccount": "Switch / Sign In",
      "colab.gpuLabel": "Accelerator",
      "colab.g4Hint": "Never pass --high-mem for G4",
      "colab.g4Note": "Standard shape (176.9GB RAM) · No high-mem",
      "colab.a100Note": "Dual-disk layout · Uses --high-mem",
      "colab.sessionName": "Session Name",
      "colab.deployBtn": "Provision & Deploy",
      "colab.attachBtn": "Attach Losslessly",
      "colab.attachNote": "Read-only probe for GPU, processes & tunnel URL without interrupting active inference.",
      "colab.balance": "Balance (CU)",
      "colab.burnRate": "Burn Rate (CU/h)",
      "colab.keepalive": "12m Keepalive",
      "colab.stopBtn": "Release Cloud Instance",
      "engine.title": "Inference Engine & Mode",
      "engine.advancedOptions": "Advanced (HF Repo / Context / Thresholds)",
      "engine.contextLimit": "Max Context",
      "engine.visionLabel": "Vision",
      "engine.saveMayaConfig": "Save Maya Config",
      "strata.callout": "Connect directly to a remote or LAN Strata node (/health, /status, /metrics, /v1/*), or launch on Colab via --engine strata.",
      "strata.urlLabel": "Strata Node URL",
      "strata.modelLabel": "Model ID",
      "strata.maxCtxLabel": "Max Context",
      "strata.apiKeyLabel": "Optional API Key",
      "strata.connectBtn": "Connect & Mount Strata",
      "cred.stripTitle": "Credentials (~/.config/maya-gcs/)",
      "tabs.console": "Native WebUI",
      "tabs.telemetry": "Telemetry & Probe",
      "tabs.clients": "Client Integration",
      "stage.upstream": "Upstream",
      "stage.localProxy": "Gateway",
      "stage.reloadEmbed": "Reload Frame",
      "stage.syncPi": "Sync to Pi",
      "stage.iframeLoading": "Loading embedded console...",
      "stage.fallbackOpen": "Open in new tab if blocked ↗",
      "deploy.pipelineTitle": "Cloud Inference Deployment Pipeline",
      "deploy.idleSummary": "No active engine mounted yet. Deploy a new Colab runtime, attach losslessly to a running session, or mount a Strata node.",
      "deploy.quickAttachTitle": "Already running easycolab?",
      "deploy.quickAttachDesc": "Probe GPU, /mnt/hf mounts, and Cloudflare Tunnel read-only and bind immediately to http://127.0.0.1:18766.",
      "deploy.quickAttachBtn": "Lossless Attach easycolab",
      "deploy.quickStrataBtn": "Configure Strata",
      "telemetry.prefillSub": "Latest prompt throughput",
      "telemetry.decodeSub": "Latest decode throughput",
      "telemetry.vramHit": "VRAM Hit Rate",
      "telemetry.vramSub": "Hot expert VRAM residency",
      "telemetry.totalReq": "Total Requests",
      "telemetry.totalReqSub": "Served completions",
      "telemetry.queue": "Active Queue",
      "telemetry.idle": "Idle",
      "telemetry.busy": "Inferring",
      "telemetry.recentRequests": "Recent Requests",
      "table.time": "Time / ID",
      "table.tokens": "Tokens (In / Out)",
      "table.status": "Status",
      "table.empty": "No recent request telemetry recorded",
      "probe.title": "Quick Chat Probe (/v1/chat/completions)",
      "probe.maxTokens": "max_tokens",
      "probe.sendBtn": "Send Probe",
      "clients.piTitle": "Pi & pi-web Auto-Sync",
      "clients.piDesc": "Updates $HOME/.pi/agent/models.json and notifies pi-web (127.0.0.1:30141). Local gateway http://127.0.0.1:18766/v1 is recommended.",
      "clients.useLocalProxy": "Use Local Proxy (Recommended)",
      "clients.syncNow": "Sync to Pi Now",
      "clients.syncIdle": "Click to write active model & Base URL into local Pi configuration.",
      "logs.title": "Commands & Live Logs",
      "logs.connecting": "Connecting",
      "logs.live": "Live SSE",
      "logs.reconnecting": "Reconnecting",
      "logs.catAll": "All",
      "logs.catDeploy": "Deploy",
      "logs.catColab": "Colab",
      "logs.catKeepalive": "Keepalive",
      "logs.catCmd": "Cmd",
      "logs.autoScroll": "Follow",
      "logs.clear": "Clear",
      "logs.quickDiag": "Safe Diagnostics",
      "logs.runCmd": "Run",
      "modal.authTitle": "Google Colab OAuth Login",
      "modal.authDesc": "Generate the OAuth URL, sign in via browser, and paste the callback URL or authorization code below.",
      "modal.authUrlLabel": "Step 1: Generate & open auth link",
      "modal.genAuthUrl": "Generate URL",
      "modal.authCodeLabel": "Step 2: Paste auth code or callback URL",
      "modal.logoutBtn": "Sign Out",
      "modal.submitAuth": "Submit Auth",
      "modal.stopTitle": "Release Cloud Colab Instance?",
      "modal.stopWarn": "⚠️ Irreversible: unpersisted RAM and ephemeral container state will be reclaimed.",
      "modal.confirmStop": "Confirm Release",
      "modal.credTitle": "External Credentials (~/.config/maya-gcs/)",
      "modal.credSecurityNote": "Stored locally in ~/.config/maya-gcs/ (0700 dir / 0600 files). Leave blank to keep existing values.",
      "modal.pickJsonFile": "Load .json",
      "modal.mayaKeyLabel": "Maya Public Gateway Key (maya-api-key)",
      "modal.genMayaKey": "🎲 Randomize",
      "modal.clearKey": "Clear",
      "modal.saveCreds": "Save Securely",
      "modal.guideTitle": "Maya · Strata Studio Quick Guide",
    },
  };

  const CF_TUNNEL_REGEX = new RegExp("https?://[a-zA-Z0-9-]+\\.trycloudflare\\.com", "gi");
  const EMAIL_REGEX = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
  const HF_TOKEN_REGEX = new RegExp("hf_[A-Za-z0-9]{10,}", "g");
  const VM_ID_REGEX = new RegExp("\\bgpu-(?:g4|a100|h100|l4|t4)-[a-z0-9-]+", "gi");

  const ui = {
    lang: localStorage.getItem("maya_studio_lang") === "en" ? "en" : "zh",
    privacyMask: localStorage.getItem("maya_studio_privacy") !== "false",
    activeTab: "console",
    selectedGpu: "g4",
    selectedEnginePanel: "maya",
    selectedMode: "b1_pure_hf",
    visionOn: true,
    logCategory: "all",
    logQuery: "",
    autoScroll: true,
    logs: [],
    seenLogIds: new Set(),
    lastState: null,
    hydratedFromServer: false,
    dirtyInputs: new Set(),
    elapsedAnchorSec: 0,
    elapsedAnchorMs: 0,
    elapsedTicker: null,
    currentIframeSrc: "",
    currentUpstreamKey: "",
    pollTimer: null,
    pollInFlight: false,
    eventSource: null,
    iframeLoadTimer: null,
    rawSnippets: { pi: "", cursor: "", claude: "", openai: "" },
  };

  const $ = (id) => document.getElementById(id);

  function t(key) {
    const dict = I18N[ui.lang] || I18N.zh;
    return dict[key] || I18N.zh[key] || key;
  }

  function applyI18n() {
    document.querySelectorAll("[data-i18n]").forEach((el) => {
      const key = el.getAttribute("data-i18n");
      if (key) el.textContent = t(key);
    });
    const langLabel = $("langLabel");
    if (langLabel) {
      langLabel.textContent = ui.lang === "zh" ? "中 / EN" : "EN / 中";
    }
    const searchInput = $("logSearchInput");
    if (searchInput) {
      searchInput.placeholder = ui.lang === "zh" ? "搜索日志关键词..." : "Filter logs...";
    }
    const cmdInput = $("customCmdInput");
    if (cmdInput) {
      cmdInput.placeholder = ui.lang === "zh" ? "输入安全诊断命令并回车运行..." : "Run safe diagnostic command...";
    }
  }

  function escapeHtml(str) {
    return String(str ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function maskEmail(email) {
    if (!email) return "";
    if (!ui.privacyMask) return email;
    const parts = String(email).split("@");
    if (parts.length !== 2) return "***";
    const local = parts[0];
    const keep = local.length <= 2 ? local.slice(0, 1) : local.slice(0, 2);
    return `${keep}***@${parts[1]}`;
  }

  function maskUrl(url) {
    if (!url) return "";
    if (!ui.privacyMask) return url;
    const raw = String(url).trim();
    if (!raw) return "";
    try {
      const parsed = new URL(raw);
      const host = parsed.hostname.toLowerCase();
      if (host === "127.0.0.1" || host === "localhost" || host === "::1") {
        return raw;
      }
      if (host.endsWith(".trycloudflare.com")) {
        const suffix = parsed.pathname === "/" ? "" : parsed.pathname;
        return `${parsed.protocol}//******.trycloudflare.com${suffix}`;
      }
      const maskedHost =
        host.length > 6 ? `${host.slice(0, 3)}***${host.slice(-3)}` : "***";
      const portPart = parsed.port ? `:${parsed.port}` : "";
      const pathPart = parsed.pathname === "/" ? "" : parsed.pathname;
      return `${parsed.protocol}//${maskedHost}${portPart}${pathPart}`;
    } catch {
      return raw.replace(CF_TUNNEL_REGEX, "https://******.trycloudflare.com");
    }
  }

  function maskBucket(bucket) {
    if (!bucket) return "";
    if (!ui.privacyMask) return bucket;
    const s = String(bucket).trim();
    if (s.length <= 4) return "****";
    return `${s.slice(0, 2)}***${s.slice(-2)}`;
  }

  function maskText(text) {
    let out = String(text ?? "");
    if (!ui.privacyMask) return out;
    out = out.replace(CF_TUNNEL_REGEX, "https://******.trycloudflare.com");
    out = out.replace(EMAIL_REGEX, (m) => maskEmail(m));
    out = out.replace(HF_TOKEN_REGEX, "hf_********");
    out = out.replace(VM_ID_REGEX, "gpu-***");
    const bucket = ui.lastState?.credentials?.gcs_bucket;
    if (bucket && bucket.length >= 4 && out.includes(bucket)) {
      out = out.split(bucket).join(maskBucket(bucket));
    }
    const upstreamUrl = ui.lastState?.engine?.upstream_url;
    if (upstreamUrl && !upstreamUrl.includes("127.0.0.1") && !upstreamUrl.includes("localhost")) {
      if (out.includes(upstreamUrl)) {
        out = out.split(upstreamUrl).join(maskUrl(upstreamUrl));
      }
      try {
        const upHost = new URL(upstreamUrl).hostname;
        if (upHost && upHost.length >= 4 && out.includes(upHost)) {
          out = out.split(upHost).join("******");
        }
      } catch {
        // ignore invalid URL
      }
    }
    return out;
  }

  function showToast(message, type = "ok") {
    const stack = $("toastStack");
    if (!stack) return;
    const node = document.createElement("div");
    node.className = `toast toast--${type}`;
    node.textContent = message;
    stack.appendChild(node);
    setTimeout(() => {
      node.remove();
    }, 3600);
  }

  async function copyToClipboard(text, label = "") {
    const val = String(text ?? "");
    if (!val) {
      showToast(ui.lang === "zh" ? "当前无可复制内容" : "Nothing to copy", "warn");
      return;
    }
    try {
      await navigator.clipboard.writeText(val);
      showToast(
        label
          ? `${label} ${ui.lang === "zh" ? "已复制到剪贴板" : "copied"}`
          : ui.lang === "zh" ? "已复制到剪贴板" : "Copied to clipboard",
        "ok"
      );
    } catch {
      const ta = document.createElement("textarea");
      ta.value = val;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand("copy");
        showToast(ui.lang === "zh" ? "已复制到剪贴板" : "Copied to clipboard", "ok");
      } catch {
        showToast(ui.lang === "zh" ? "复制失败，请手动选择" : "Copy failed", "err");
      } finally {
        ta.remove();
      }
    }
  }

  async function apiRequest(path, options = {}) {
    const controller = new AbortController();
    const timeoutMs = options.timeoutMs || 45000;
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const fetchOpts = {
        method: options.method || "GET",
        headers: {
          "Content-Type": "application/json",
          ...(options.headers || {}),
        },
        signal: controller.signal,
      };
      if (options.body !== undefined) {
        fetchOpts.body = JSON.stringify(options.body);
      }
      const resp = await fetch(path, fetchOpts);
      const text = await resp.text();
      let data = {};
      if (text) {
        try {
          data = JSON.parse(text);
        } catch {
          data = { ok: resp.ok, raw: text };
        }
      }
      if (!resp.ok || data.ok === false) {
        const errMsg = data.error || data.message || `HTTP ${resp.status}`;
        throw new Error(errMsg);
      }
      return data;
    } catch (err) {
      if (err && err.name === "AbortError") {
        throw new Error(ui.lang === "zh" ? "请求超时，请查看右侧实时日志" : "Request timed out");
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  function setButtonBusy(btn, busy, busyLabel) {
    if (!btn) return;
    if (busy) {
      if (!btn.dataset.origHtml) {
        btn.dataset.origHtml = btn.innerHTML;
      }
      btn.disabled = true;
      if (busyLabel) btn.textContent = busyLabel;
    } else {
      btn.disabled = false;
      if (btn.dataset.origHtml) {
        btn.innerHTML = btn.dataset.origHtml;
        delete btn.dataset.origHtml;
      }
    }
  }

  function getProxyBaseUrl(state) {
    const s = state || ui.lastState;
    if (s?.engine?.proxy_url) return s.engine.proxy_url.replace(/\/+$/, "");
    const port = s?.ports?.proxy || 18766;
    const host = window.location.hostname || "127.0.0.1";
    return `http://${host}:${port}`;
  }

  function getOpenAIBaseUrl(state) {
    const s = state || ui.lastState;
    if (s?.engine?.openai_base_url) return s.engine.openai_base_url.replace(/\/+$/, "");
    return `${getProxyBaseUrl(s)}/v1`;
  }

  function getSessionValue() {
    const val = $("sessionInput")?.value?.trim();
    return val || "easycolab";
  }

  function syncInputIfNotDirty(el, value) {
    if (!el || value === undefined || value === null) return;
    if (document.activeElement === el) return;
    if (ui.dirtyInputs.has(el.id)) return;
    const str = String(value);
    if (el.value !== str) {
      el.value = str;
    }
  }

  function normalizeModes(catalog) {
    if (!Array.isArray(catalog) || catalog.length === 0) {
      return DEFAULT_MODES;
    }
    const mapById = new Map(DEFAULT_MODES.map((m) => [m.id, m]));
    return catalog.map((item) => {
      const id = item.id || item.mode || item.key;
      const base = mapById.get(id) || {};
      return {
        id,
        title_zh: item.title_zh || item.name || item.label || base.title_zh || id,
        title_en: item.title_en || item.name_en || item.label_en || item.label || base.title_en || id,
        desc_zh: item.desc_zh || item.short_desc || item.description || base.desc_zh || "",
        desc_en: item.desc_en || item.description_en || base.desc_en || item.short_desc || "",
        badge: item.badge || "",
        recommended: Boolean(item.recommended ?? base.recommended),
      };
    });
  }

  function renderMayaModes() {
    const container = $("mayaModesList");
    if (!container) return;
    const modes = normalizeModes(ui.lastState?.modes_catalog);
    container.innerHTML = "";
    modes.forEach((mode) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `mode-card${ui.selectedMode === mode.id ? " is-selected" : ""}`;
      btn.setAttribute("role", "radio");
      btn.setAttribute("aria-checked", ui.selectedMode === mode.id ? "true" : "false");
      btn.dataset.modeId = mode.id;

      const title = ui.lang === "zh" ? mode.title_zh : mode.title_en;
      const desc = ui.lang === "zh" ? mode.desc_zh : mode.desc_en;

      btn.innerHTML = `
        <span class="mode-card-top">
          <span>${escapeHtml(title)}</span>
          ${mode.recommended ? `<span class="rec-tag">${escapeHtml(t("common.recommended"))}</span>` : ""}
        </span>
        <span class="mode-card-desc">${escapeHtml(desc)}</span>
      `;
      btn.addEventListener("click", () => {
        const changed = ui.selectedMode !== mode.id;
        ui.selectedMode = mode.id;
        renderMayaModes();
        if (changed) {
          // 切换 Maya 加速模式卡片后自动持久化保存，避免用户误以为点选即生效却忘记点底部保存按钮
          const settings = collectSettingsPayload();
          apiRequest("/api/studio/engine/configure", {
            method: "POST",
            body: {
              kind: "maya",
              mode: mode.id,
              upstream_url: ui.lastState?.engine?.upstream_url || "",
              settings,
            },
          })
            .then(() => refreshStateNow())
            .then(() => {
              showToast(
                ui.lang === "zh" ? `已切换并保存：${mode.title_zh}` : `Saved mode: ${mode.title_en}`
              );
            })
            .catch(() => {});
        }
      });
      container.appendChild(btn);
    });
  }

  function renderGpuSelection() {
    document.querySelectorAll("#gpuSelectGroup .gpu-option").forEach((btn) => {
      const active = btn.dataset.gpu === ui.selectedGpu;
      btn.classList.toggle("is-selected", active);
      btn.setAttribute("aria-checked", active ? "true" : "false");
    });
  }

  function renderEngineSegment() {
    const isMaya = ui.selectedEnginePanel === "maya";
    $("segEngineMaya")?.classList.toggle("is-active", isMaya);
    $("segEngineMaya")?.setAttribute("aria-selected", isMaya ? "true" : "false");
    $("segEngineStrata")?.classList.toggle("is-active", !isMaya);
    $("segEngineStrata")?.setAttribute("aria-selected", !isMaya ? "true" : "false");

    $("mayaModePanel")?.classList.toggle("hidden", !isMaya);
    $("strataModePanel")?.classList.toggle("hidden", isMaya);
  }

  function formatElapsed(sec) {
    const total = Math.max(0, Math.floor(Number(sec) || 0));
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n) => String(n).padStart(2, "0");
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
  }

  function getLiveElapsedSec(deployment, engineOnline) {
    const base = Number(deployment?.elapsed_sec || 0);
    const phase = String(deployment?.phase || "idle").toLowerCase();
    if (!engineOnline && phase !== "idle" && phase !== "ready" && phase !== "error" && ui.elapsedAnchorMs > 0) {
      return ui.elapsedAnchorSec + Math.floor((Date.now() - ui.elapsedAnchorMs) / 1000);
    }
    return base;
  }

  function resolveDeployPercent(deployment, engineOnline, stepIndex) {
    if (engineOnline) return 100;
    if (typeof deployment?.percent === "number" && Number.isFinite(deployment.percent)) {
      return Math.max(0, Math.min(100, deployment.percent));
    }
    return Math.round((stepIndex / 6) * 100);
  }

  const STEP_PERCENT_RANGES = {
    1: [0, 6],
    2: [6, 14],
    3: [14, 48],
    4: [48, 54],
    5: [54, 56],
    6: [56, 100],
  };

  function resolveStepSubPercent(stepNum, done, active, deployment, totalPct) {
    if (done) return 100;
    if (!active) return 0;
    const rawSub = deployment?.sub_percent;
    if (typeof rawSub === "number" && Number.isFinite(rawSub)) {
      return Math.max(0, Math.min(100, rawSub));
    }
    const range = STEP_PERCENT_RANGES[stepNum];
    if (range && typeof totalPct === "number" && Number.isFinite(totalPct)) {
      const [lo, hi] = range;
      const span = Math.max(1, hi - lo);
      return Math.max(4, Math.min(99, ((totalPct - lo) / span) * 100));
    }
    return 10;
  }

  function buildEtaSummary(deployment, engineOnline) {
    const elapsed = getLiveElapsedSec(deployment, engineOnline);
    const elapsedPart = elapsed > 0 ? `${ui.lang === "zh" ? "已用" : "Elapsed"} ${formatElapsed(elapsed)}` : "";
    const etaRaw = String(deployment?.eta_text || "").trim();
    if (elapsedPart && etaRaw) return `${elapsedPart} · ${etaRaw}`;
    return etaRaw || elapsedPart || (engineOnline ? (ui.lang === "zh" ? "已就绪" : "Ready") : "--");
  }

  function renderDeploySteps(deployment, engineOnline) {
    const grid = $("deployStepsGrid");
    if (!grid) return;
    const phase = String(deployment?.phase || "idle").toLowerCase();
    const hasUpstream = Boolean(ui.lastState?.engine?.upstream_url);
    const staleIdleOrReady = !engineOnline && (phase === "idle" || (phase === "ready" && !hasUpstream));
    const rawIndex = staleIdleOrReady ? 0 : Number(deployment?.step_index || 0);
    const stepIndex = engineOnline ? 6 : Math.max(0, Math.min(6, rawIndex));
    const isDeploying =
      !engineOnline &&
      phase !== "idle" &&
      phase !== "ready" &&
      phase !== "error" &&
      stepIndex > 0 &&
      !deployment?.error;
    const isWarmingWithUpstream = !engineOnline && hasUpstream && !deployment?.error;
    const pct = staleIdleOrReady ? 0 : resolveDeployPercent(deployment, engineOnline, stepIndex);
    const pctStr = `${pct.toFixed(pct > 0 && pct < 100 ? 1 : 0)}%`;

    const counter = $("deployStepCounter");
    if (counter) counter.textContent = `${stepIndex} / 6`;

    const pctBadge = $("deployPercentBadge");
    if (pctBadge) pctBadge.textContent = pctStr;

    const bar = $("deployProgressBar");
    if (bar) {
      bar.style.width = `${pct}%`;
      bar.classList.toggle("is-active", isDeploying || isWarmingWithUpstream);
    }

    const detailEl = $("deployDetailText");
    if (detailEl) {
      if (deployment?.error) {
        detailEl.textContent = deployment.error;
      } else if (!staleIdleOrReady && deployment?.detail) {
        detailEl.textContent = deployment.detail;
      } else {
        detailEl.textContent =
          ui.lang === "zh"
            ? "首次冷启预计总耗时 ~22–28 分钟（分片拉取 ~9m + 显存/内存装载 ~15m）"
            : "Typical cold boot takes ~22–28m (shard download ~9m + VRAM/RAM load ~15m)";
      }
    }

    const etaEl = $("deployEtaText");
    if (etaEl) {
      etaEl.textContent = staleIdleOrReady ? "--" : buildEtaSummary(deployment, engineOnline);
    }

    const summary = $("deployStatusSummary");
    if (summary) {
      if (engineOnline) {
        summary.textContent = deployment?.step_label || t("status.online");
      } else if (staleIdleOrReady) {
        summary.textContent = t("deploy.idleSummary");
      } else if (deployment?.step_label && deployment.step_label !== "部署完成，引擎在线") {
        summary.textContent = deployment.step_label;
      } else if (isDeploying || isWarmingWithUpstream) {
        summary.textContent =
          ui.lang === "zh" ? "隧道已连通 · 正在等待远端引擎完成权重装入..." : "Tunnel connected · Loading weights into VRAM/RAM...";
      } else {
        summary.textContent = t("deploy.idleSummary");
      }
    }

    const errBanner = $("deployErrorBanner");
    if (errBanner) {
      if (deployment?.error) {
        errBanner.textContent = deployment.error;
        errBanner.classList.remove("hidden");
      } else {
        errBanner.classList.add("hidden");
      }
    }

    grid.innerHTML = "";
    DEPLOY_STEPS.forEach((item) => {
      const done = !staleIdleOrReady && (engineOnline || (stepIndex > item.step) || (item.step < 6 && stepIndex === 6 && !deployment?.error));
      const active = !staleIdleOrReady && !done && !deployment?.error && (stepIndex === item.step);
      const subPct = staleIdleOrReady ? 0 : resolveStepSubPercent(item.step, done, active, deployment, pct);
      const el = document.createElement("div");
      el.className = `step-item${done ? " is-done" : ""}${active ? " is-active" : ""}`;
      el.innerHTML = `
        <span class="step-num tabular-nums">${done ? "✓" : item.step}</span>
        <span class="step-label-wrap">
          <span class="step-name">${escapeHtml(ui.lang === "zh" ? item.zh : item.en)}</span>
          <span class="step-sub">${escapeHtml(ui.lang === "zh" ? item.sub_zh : item.sub_en)}</span>
          <span class="step-sub-bar" aria-hidden="true"><span class="step-sub-fill" style="width:${subPct.toFixed(1)}%"></span></span>
        </span>
      `;
      grid.appendChild(el);
    });
  }

  function renderRightProgressCard(state) {
    const card = $("rightDeployProgressCard");
    if (!card) return;
    const engine = state?.engine || {};
    const deploy = state?.deployment || {};
    const engineOnline = Boolean(engine.online) && engine.loaded !== false;
    const stepIndex = Number(deploy.step_index || 0);
    const phase = String(deploy.phase || "idle").toLowerCase();
    const isActive =
      !engineOnline &&
      !deploy.error &&
      ((phase !== "idle" && phase !== "ready" && phase !== "error" && stepIndex > 0) || Boolean(engine.upstream_url));
    const isError = !engineOnline && Boolean(deploy.error);

    if (!engineOnline && !isActive && !isError) {
      card.classList.add("hidden");
      card.classList.remove("is-ready", "is-error");
      return;
    }

    card.classList.remove("hidden");
    card.classList.toggle("is-ready", engineOnline);
    card.classList.toggle("is-error", isError);

    const pct = isError ? resolveDeployPercent(deploy, false, stepIndex) : resolveDeployPercent(deploy, engineOnline, stepIndex || 6);
    const pctStr = `${pct.toFixed(pct > 0 && pct < 100 ? 1 : 0)}%`;

    const titleEl = $("rightProgressTitle");
    const pctEl = $("rightProgressPct");
    const fillEl = $("rightProgressFill");
    const detailEl = $("rightProgressDetail");
    const etaEl = $("rightProgressEta");

    if (engineOnline) {
      if (titleEl) titleEl.textContent = ui.lang === "zh" ? "✓ 推理引擎已全部装载就绪" : "✓ Inference Engine Loaded & Ready";
      if (pctEl) pctEl.textContent = "100%";
      if (fillEl) {
        fillEl.style.width = "100%";
        fillEl.classList.remove("is-active");
      }
      if (detailEl) {
        const modelStr = engine.model_id || "deepseek-v4.1-flash-abliterated";
        detailEl.textContent = `${modelStr} · VRAM + RAM 常驻`;
      }
      if (etaEl) {
        const elap = Number(deploy.elapsed_sec || 0);
        etaEl.textContent = elap > 0 ? `${ui.lang === "zh" ? "耗时" : "Took"} ${formatElapsed(elap)}` : (ui.lang === "zh" ? "随时可调用" : "Ready");
      }
      return;
    }

    if (isError) {
      if (titleEl) titleEl.textContent = ui.lang === "zh" ? "✕ 部署或启动中断" : "✕ Deployment Interrupted";
      if (pctEl) pctEl.textContent = pctStr;
      if (fillEl) {
        fillEl.style.width = `${Math.max(4, pct)}%`;
        fillEl.classList.remove("is-active");
      }
      if (detailEl) detailEl.textContent = deploy.error || "--";
      if (etaEl) etaEl.textContent = buildEtaSummary(deploy, false);
      return;
    }

    const fallbackWarm = ui.lang === "zh" ? "隧道已连通 · 正在将权重装入显存与内存..." : "Tunnel up · Loading weights into VRAM/RAM...";
    const lbl = deploy.step_label && deploy.step_label !== "部署完成，引擎在线" ? deploy.step_label : fallbackWarm;
    if (titleEl) titleEl.textContent = `[${stepIndex || 6}/6] ${lbl}`;
    if (pctEl) pctEl.textContent = pctStr;
    if (fillEl) {
      fillEl.style.width = `${Math.max(2, pct)}%`;
      fillEl.classList.add("is-active");
    }
    if (detailEl) detailEl.textContent = deploy.detail || (ui.lang === "zh" ? "等待远端心跳..." : "Polling remote node...");
    if (etaEl) etaEl.textContent = buildEtaSummary(deploy, false);
  }

  function renderSnippets(state) {
    const useLocal = $("chkUseLocalProxy") ? $("chkUseLocalProxy").checked : true;
    const rawUp = state?.engine?.upstream_url || "";
    const maskedUp = state?.engine?.upstream_masked || (rawUp ? maskUrl(rawUp) : "");
    const displayUpstream = ui.privacyMask ? maskedUp : (rawUp || maskedUp);
    const copyUpstream = rawUp || maskedUp;
    const modelId = state?.engine?.model_id || state?.settings?.strata_model || "deepseek-v4.1-flash-abliterated";
    const maxCtx = Number(state?.settings?.strata_max_context || state?.settings?.max_context || 262144);
    const hasApiKey = Boolean(state?.engine?.has_api_key);
    const apiKeyHint = !useLocal && hasApiKey ? "sk-maya-******" : "studio-local-proxy";

    const buildSnippetsForUpstream = (upstreamValue) => {
      const openaiBase = !useLocal && upstreamValue ? `${upstreamValue.replace(/\/+$/, "")}/v1` : getOpenAIBaseUrl(state);
      const proxyRoot = !useLocal && upstreamValue ? upstreamValue.replace(/\/+$/, "") : getProxyBaseUrl(state);

      const pi = JSON.stringify(
        {
          providers: {
            "maya-studio": {
              baseUrl: openaiBase,
              api: "openai-completions",
              apiKey: apiKeyHint,
              models: [
                {
                  id: modelId,
                  name: `Maya Studio (${modelId})`,
                  reasoning: true,
                  input: ["text", "image"],
                  contextWindow: maxCtx,
                  maxTokens: 65536,
                },
              ],
            },
          },
        },
        null,
        2
      );

      const cursor = JSON.stringify(
        {
          "openai.baseUrl": openaiBase,
          "openai.apiKey": apiKeyHint,
          "openai.model": modelId,
        },
        null,
        2
      );

      const claude = [
        `export ANTHROPIC_BASE_URL="${proxyRoot}"`,
        `export ANTHROPIC_AUTH_TOKEN="${apiKeyHint}"`,
        `export ANTHROPIC_MODEL="${modelId}"`,
      ].join("\n");

      const openai = [
        "from openai import OpenAI",
        "",
        "client = OpenAI(",
        `    base_url="${openaiBase}",`,
        `    api_key="${apiKeyHint}",`,
        ")",
        "resp = client.chat.completions.create(",
        `    model="${modelId}",`,
        '    messages=[{"role": "user", "content": "Hello"}],',
        "    max_tokens=256,",
        ")",
        "print(resp.choices[0].message.content)",
      ].join("\n");

      return { pi, cursor, claude, openai };
    };

    const displaySnippets = buildSnippetsForUpstream(displayUpstream);
    // 剪贴板片段始终保留未打码的真实上游 URL（前台打码仅作用于屏幕 DOM 展示）
    ui.rawSnippets = buildSnippetsForUpstream(copyUpstream);

    const map = {
      snippetPi: displaySnippets.pi,
      snippetCursor: displaySnippets.cursor,
      snippetClaude: displaySnippets.claude,
      snippetOpenai: displaySnippets.openai,
    };
    Object.entries(map).forEach(([id, content]) => {
      const node = $(id);
      if (node) node.textContent = content;
    });
  }

  function renderRecentRequests(list) {
    const body = $("recentRequestsBody");
    const countBadge = $("recentReqCount");
    const items = Array.isArray(list) ? list : [];
    if (countBadge) {
      countBadge.textContent = ui.lang === "zh" ? `${items.length} 条` : `${items.length}`;
    }
    if (!body) return;
    if (items.length === 0) {
      body.innerHTML = `<tr><td colspan="5" class="table-empty">${escapeHtml(t("table.empty"))}</td></tr>`;
      return;
    }
    body.innerHTML = items
      .slice(0, 20)
      .map((req) => {
        const label = req.ts || req.time || req.id || req.req_id || "--";
        const inTok = req.prompt_tokens ?? req.input_tokens ?? "--";
        const outTok = req.completion_tokens ?? req.output_tokens ?? "--";
        const prefill = req.prefill_tok_s != null ? `${Number(req.prefill_tok_s).toFixed(1)} tok/s` : "--";
        const decode = req.decode_tok_s != null ? `${Number(req.decode_tok_s).toFixed(1)} tok/s` : "--";
        const status = req.status || (req.ok === false ? "error" : (req.duration_s != null ? `${Number(req.duration_s).toFixed(1)}s` : "ok"));
        return `
          <tr>
            <td class="mono tabular-nums">${escapeHtml(label)}</td>
            <td class="mono tabular-nums">${escapeHtml(inTok)} / ${escapeHtml(outTok)}</td>
            <td class="num mono tabular-nums">${escapeHtml(prefill)}</td>
            <td class="num mono tabular-nums">${escapeHtml(decode)}</td>
            <td><span class="mini-badge ${status === "error" ? "mini-badge--amber" : "mini-badge--green"}">${escapeHtml(status)}</span></td>
          </tr>
        `;
      })
      .join("");
  }

  function updateIframeVisibility(state) {
    const engine = state?.engine || {};
    const online = Boolean(engine.online);
    const onlineWrap = $("consoleOnlineWrap");
    const offlineWrap = $("consoleOfflineWrap");
    const frame = $("engineWebuiFrame");
    const proxyBase = getProxyBaseUrl(state);

    if (online) {
      onlineWrap?.classList.remove("hidden");
      offlineWrap?.classList.add("hidden");

      const upstreamKey = `${engine.kind || "maya"}|${engine.upstream_url || ""}|${proxyBase}`;
      const targetSrc = `${proxyBase}/`;

      const label = $("iframeStatusLabel");
      if (label) {
        label.textContent =
          ui.lang === "zh"
            ? `已通过本地同源代理 ${proxyBase.replace(/^https?:\/\//, "")} 接入原生控制台`
            : `Mounted via same-origin proxy ${proxyBase}`;
      }

      if (frame && (ui.currentIframeSrc !== targetSrc || ui.currentUpstreamKey !== upstreamKey)) {
        ui.currentIframeSrc = targetSrc;
        ui.currentUpstreamKey = upstreamKey;
        loadIframeTarget(targetSrc);
      }
    } else {
      onlineWrap?.classList.add("hidden");
      offlineWrap?.classList.remove("hidden");
    }
  }

  function loadIframeTarget(src) {
    const frame = $("engineWebuiFrame");
    const loadingChip = $("iframeLoadingChip");
    if (!frame) return;
    loadingChip?.classList.remove("hidden");
    if (ui.iframeLoadTimer) clearTimeout(ui.iframeLoadTimer);
    ui.iframeLoadTimer = setTimeout(() => {
      loadingChip?.classList.add("hidden");
    }, 8000);
    frame.src = src;
  }

  function renderState(state) {
    if (!state) return;
    const prevState = ui.lastState;
    const prevBucket = prevState?.credentials?.gcs_bucket || "";
    const prevUpstream = prevState?.engine?.upstream_url || "";
    const prevEmail = prevState?.colab?.email || "";
    ui.lastState = state;

    const colab = state.colab || {};
    const engine = state.engine || {};
    const deploy = state.deployment || {};
    const creds = state.credentials || {};
    const settings = state.settings || {};
    const telemetry = engine.telemetry || {};

    ui.elapsedAnchorSec = Number(deploy.elapsed_sec || 0);
    ui.elapsedAnchorMs = Date.now();

    // Hydrate user choices once on first poll
    if (!ui.hydratedFromServer) {
      if (colab.selected_gpu) ui.selectedGpu = String(colab.selected_gpu).toLowerCase();
      if (engine.kind) ui.selectedEnginePanel = engine.kind === "strata" ? "strata" : "maya";
      if (engine.mode) ui.selectedMode = engine.mode;
      if (colab.selected_session && $("sessionInput")) {
        $("sessionInput").value = colab.selected_session;
      }
      if (settings.vision_enabled !== undefined) {
        ui.visionOn = Boolean(settings.vision_enabled);
        const vBtn = $("btnVisionToggle");
        const vTxt = $("visionToggleText");
        if (vBtn) {
          vBtn.classList.toggle("is-on", ui.visionOn);
          vBtn.setAttribute("aria-checked", ui.visionOn ? "true" : "false");
        }
        if (vTxt) vTxt.textContent = ui.visionOn ? "--vision on" : "--vision off";
      }
      if (settings.max_context != null && $("mayaContextSelect")) {
        $("mayaContextSelect").value = String(settings.max_context);
      }
      ui.hydratedFromServer = true;
    }

    renderGpuSelection();
    renderEngineSegment();
    renderMayaModes();

    // Topbar status pill
    const pill = $("topStatusPill");
    const pillText = $("topStatusText");
    const deployPhase = String(deploy.phase || "idle").toLowerCase();
    const isDeploying =
      !engine.online &&
      deployPhase !== "idle" &&
      deployPhase !== "ready" &&
      deployPhase !== "error" &&
      Number(deploy.step_index || 0) > 0 &&
      !deploy.error;
    const hasUpstream = Boolean(engine.upstream_url);
    if (pill && pillText) {
      pill.classList.remove("status-pill--online", "status-pill--loading", "status-pill--offline");
      if (engine.online && engine.loaded !== false) {
        pill.classList.add("status-pill--online");
        pillText.textContent = t("status.online");
      } else if (isDeploying || hasUpstream || (engine.online && engine.loaded === false)) {
        pill.classList.add("status-pill--loading");
        const pct = resolveDeployPercent(deploy, false, Number(deploy.step_index || 0));
        const pctPrefix = pct > 0 ? `[${pct.toFixed(pct < 100 ? 1 : 0)}%] ` : "";
        const fallbackWarm =
          ui.lang === "zh" ? "隧道已通 · 权重装入显存中..." : "Tunnel up · Loading weights...";
        const lbl = deploy.step_label && deploy.step_label !== "部署完成，引擎在线" ? deploy.step_label : fallbackWarm;
        pillText.textContent = `${pctPrefix}${lbl}`;
      } else {
        pill.classList.add("status-pill--offline");
        pillText.textContent = t("status.standby");
      }
    }

    // Engine badge in topbar
    const topEngineBadge = $("topEngineBadge");
    if (topEngineBadge) {
      const isStrata = engine.kind === "strata";
      topEngineBadge.classList.toggle("engine-badge--strata", isStrata);
      topEngineBadge.textContent = isStrata ? "Strata Engine (strata)" : `Project Maya (${engine.mode || ui.selectedMode})`;
    }

    // GPU chip & VM region badge in topbar
    const topGpuBadge = $("topGpuBadge");
    if (topGpuBadge) {
      if (colab.gpu_name) {
        topGpuBadge.textContent = colab.gpu_name;
        topGpuBadge.classList.remove("hidden");
      } else {
        topGpuBadge.classList.add("hidden");
      }
    }

    const vmReg = colab.vm_region && colab.vm_region.country ? colab.vm_region : null;
    const topRegionBadge = $("topRegionBadge");
    if (topRegionBadge) {
      if (vmReg) {
        topRegionBadge.textContent = ui.lang === "zh" ? (vmReg.short_label || vmReg.country) : (vmReg.short_label_en || vmReg.country);
        topRegionBadge.className = `region-chip ${vmReg.is_us ? "region-chip--us" : "region-chip--intl"}`;
        topRegionBadge.title = vmReg.is_us
          ? (ui.lang === "zh"
            ? `Colab 实例机房: ${vmReg.full_label || vmReg.country}（美区近源，HF CDN 冷启高速）`
            : `Colab VM region: ${vmReg.full_label || vmReg.country} (US origin, fast HF CDN boot)`)
          : (ui.lang === "zh"
            ? `Colab 实例机房: ${vmReg.full_label || vmReg.country}（非美区跨洲节点，冷启拉取可能偏慢；上线后推理不受影响）`
            : `Colab VM region: ${vmReg.full_label || vmReg.country} (non-US cross-region boot may be slower; inference unaffected once loaded)`);
      } else {
        topRegionBadge.className = "region-chip hidden";
        topRegionBadge.textContent = "";
        topRegionBadge.title = "";
      }
    }

    // Left Card 1: Colab
    const colabBadge = $("colabStateBadge");
    if (colabBadge) {
      const online = Boolean(colab.gpu_name || engine.online || (Array.isArray(colab.active_assignments) ? colab.active_assignments.length > 0 : Number(colab.active_assignments || 0) > 0));
      colabBadge.className = `mini-badge ${online ? "mini-badge--green" : "mini-badge--muted"}`;
      colabBadge.textContent = online ? t("colab.connected") : t("colab.disconnected");
    }

    const emailEl = $("accountEmailText");
    if (emailEl) {
      if (colab.logged_in && colab.email) {
        const displayEmail = maskEmail(colab.email);
        emailEl.textContent = displayEmail;
        emailEl.title = ui.privacyMask ? "" : colab.email;
      } else {
        emailEl.textContent = t("colab.notLoggedIn");
        emailEl.title = "";
      }
    }

    // Session chips
    const sessionChips = $("sessionChips");
    if (sessionChips) {
      const sessions = Array.isArray(colab.sessions) ? colab.sessions : [];
      sessionChips.innerHTML = "";
      sessions.slice(0, 4).forEach((s) => {
        const sName = typeof s === "string" ? s : (s?.name || s?.session || "");
        if (!sName) return;
        const chip = document.createElement("button");
        chip.type = "button";
        chip.className = "session-chip";
        chip.textContent = sName;
        chip.addEventListener("click", () => {
          const inp = $("sessionInput");
          if (inp) {
            inp.value = sName;
            ui.dirtyInputs.add("sessionInput");
          }
        });
        sessionChips.appendChild(chip);
      });
    }

    // CU Quota & Keepalive
    const balEl = $("cuBalanceValue");
    if (balEl) {
      balEl.textContent = colab.paid_balance != null ? `${Number(colab.paid_balance).toFixed(2)} CU` : "--";
    }
    const burnEl = $("cuBurnRateValue");
    if (burnEl) {
      burnEl.textContent = colab.burn_rate_hourly != null ? `${Number(colab.burn_rate_hourly).toFixed(2)} CU/h` : "--";
    }
    const kaBtn = $("btnKeepaliveToggle");
    const kaLbl = $("keepaliveLabel");
    const kaOn = Boolean(colab.keepalive_running);
    if (kaBtn && kaLbl) {
      kaBtn.classList.toggle("is-on", kaOn);
      kaBtn.setAttribute("aria-checked", kaOn ? "true" : "false");
      kaLbl.textContent = kaOn ? t("common.on") : t("common.off");
    }

    // Runtime Strip (GPU + region + mounts)
    const runtimeStrip = $("colabRuntimeStrip");
    const gpuDetected = $("colabGpuDetected");
    const mountPills = $("colabMountPills");
    if (runtimeStrip && gpuDetected && mountPills) {
      const mountsObj = colab.mounts;
      const hasMountData = mountsObj && (Array.isArray(mountsObj) ? mountsObj.length > 0 : Object.keys(mountsObj).length > 0);
      if (colab.gpu_name || hasMountData || vmReg) {
        runtimeStrip.classList.remove("hidden");
        gpuDetected.textContent = colab.gpu_name ? `GPU: ${colab.gpu_name}` : "GPU: Attached";
        mountPills.innerHTML = "";
        if (vmReg) {
          const regPill = document.createElement("span");
          regPill.className = `mount-pill ${vmReg.is_us ? "mount-pill--ok" : "mount-pill--warn"}`;
          regPill.textContent = ui.lang === "zh" ? (vmReg.short_label || vmReg.country) : (vmReg.short_label_en || vmReg.country);
          if (vmReg.full_label) regPill.title = vmReg.full_label;
          mountPills.appendChild(regPill);
        }
        if (Array.isArray(mountsObj)) {
          mountsObj.forEach((m) => {
            const sp = document.createElement("span");
            sp.className = "mount-pill mount-pill--ok";
            sp.textContent = String(m);
            mountPills.appendChild(sp);
          });
        } else if (mountsObj && typeof mountsObj === "object") {
          Object.entries(mountsObj).forEach(([k, v]) => {
            const sp = document.createElement("span");
            const ok = Boolean(v);
            sp.className = `mount-pill${ok ? " mount-pill--ok" : ""}`;
            sp.textContent = `${k}: ${typeof v === "string" ? v : ok ? "ready" : "off"}`;
            mountPills.appendChild(sp);
          });
        }
      } else {
        runtimeStrip.classList.add("hidden");
      }
    }

    // Active engine badge on Card 2
    const activeEnginePill = $("activeEnginePill");
    if (activeEnginePill) {
      activeEnginePill.textContent = engine.kind === "strata" ? "Strata" : "Maya";
      activeEnginePill.className = `mini-badge ${engine.kind === "strata" ? "mini-badge--green" : "mini-badge--blue"}`;
    }

    // Sync settings inputs carefully
    syncInputIfNotDirty($("hfRepoInput"), settings.hf_repo);
    syncInputIfNotDirty($("s2GcsThreshInput"), settings.s2_gcs_thresh);
    syncInputIfNotDirty($("s2LocalMaxInput"), settings.s2_local_max);
    syncInputIfNotDirty($("strataUrlInput"), settings.strata_url);
    syncInputIfNotDirty($("strataModelInput"), settings.strata_model);
    syncInputIfNotDirty($("strataMaxCtxInput"), settings.strata_max_context);

    // Credentials dots
    $("dotHfToken")?.classList.toggle("dot--green", Boolean(creds.has_hf_token));
    $("dotHfToken")?.classList.toggle("dot--muted", !creds.has_hf_token);
    $("dotGcsKey")?.classList.toggle("dot--green", Boolean(creds.has_gcs_key));
    $("dotGcsKey")?.classList.toggle("dot--muted", !creds.has_gcs_key);
    const hasBucket = Boolean(creds.gcs_bucket);
    $("dotBucket")?.classList.toggle("dot--green", hasBucket);
    $("dotBucket")?.classList.toggle("dot--muted", !hasBucket);
    const bucketLabel = $("credBucketLabel");
    if (bucketLabel) {
      bucketLabel.textContent = hasBucket ? `Bucket: ${maskBucket(creds.gcs_bucket)}` : "Bucket";
    }
    $("dotMayaKey")?.classList.toggle("dot--green", Boolean(creds.has_maya_key));
    $("dotMayaKey")?.classList.toggle("dot--muted", !creds.has_maya_key);
    $("dotStrataKey")?.classList.toggle("dot--green", Boolean(creds.has_strata_key));
    $("dotStrataKey")?.classList.toggle("dot--muted", !creds.has_strata_key);

    // Stage Address Pills
    const upEl = $("upstreamAddrText");
    if (upEl) {
      const rawUp = engine.upstream_url || "";
      const maskedUp = engine.upstream_masked || (rawUp ? maskUrl(rawUp) : "");
      if (!rawUp && !maskedUp) {
        upEl.textContent = ui.lang === "zh" ? "未绑定" : "Unbound";
        upEl.title = "";
      } else {
        const shown = ui.privacyMask ? (engine.upstream_masked || maskUrl(rawUp)) : (rawUp || maskedUp);
        upEl.textContent = shown;
        upEl.title = ui.privacyMask ? "" : shown;
      }
    }
    const proxyEl = $("proxyAddrText");
    if (proxyEl) {
      proxyEl.textContent = getOpenAIBaseUrl(state);
    }
    const modelPill = $("stageModelPill");
    if (modelPill) {
      if (engine.model_id) {
        modelPill.textContent = engine.model_id;
        modelPill.classList.remove("hidden");
      } else {
        modelPill.classList.add("hidden");
      }
    }

    // Center Tab 1: Iframe vs Pipeline & Right Progress Card
    updateIframeVisibility(state);
    renderDeploySteps(deploy, Boolean(engine.online) && engine.loaded !== false);
    renderRightProgressCard(state);

    // Center Tab 2: Telemetry KPIs & Recent Requests
    const setKpi = (id, val, suffix = "") => {
      const node = $(id);
      if (!node) return;
      node.textContent = val != null && !Number.isNaN(Number(val)) ? `${Number(val).toFixed(suffix === "%" || suffix === "" ? (Number.isInteger(Number(val)) ? 0 : 1) : 2)}${suffix}` : "--";
    };
    setKpi("kpiPrefill", telemetry.last_prefill_tok_s);
    setKpi("kpiDecode", telemetry.last_decode_tok_s);
    setKpi("kpiVramHit", telemetry.vram_hit_pct, "%");
    if ($("kpiRequests")) {
      $("kpiRequests").textContent = telemetry.requests_total != null ? String(telemetry.requests_total) : "--";
    }
    if ($("kpiQueue")) {
      const q = telemetry.queued != null ? Number(telemetry.queued) : 0;
      const b = telemetry.busy ? 1 : 0;
      $("kpiQueue").textContent = telemetry.queued != null || telemetry.busy != null ? `${b} / ${q}` : "--";
    }
    if ($("kpiBusySub")) {
      $("kpiBusySub").textContent = telemetry.busy ? t("telemetry.busy") : t("telemetry.idle");
    }
    renderRecentRequests(telemetry.recent_requests);

    // Center Tab 3: Snippets
    renderSnippets(state);

    // Re-render logs if state arrived for the first time or sensitive fields changed
    const nextBucket = creds.gcs_bucket || "";
    const nextUpstream = engine.upstream_url || "";
    const nextEmail = colab.email || "";
    if (
      ui.logs.length > 0 &&
      (!prevState || prevBucket !== nextBucket || prevUpstream !== nextUpstream || prevEmail !== nextEmail)
    ) {
      renderLogs();
    }
  }

  function appendLogEntry(entry) {
    if (!entry) return;
    const id = entry.id != null ? String(entry.id) : `${entry.ts || ""}_${entry.text || ""}_${ui.logs.length}`;
    if (entry.id != null && ui.seenLogIds.has(id)) return;
    if (entry.id != null) ui.seenLogIds.add(id);

    ui.logs.push({
      id,
      ts: entry.ts || new Date().toTimeString().slice(0, 8),
      category: String(entry.category || "system").toLowerCase(),
      level: String(entry.level || "info").toLowerCase(),
      text: String(entry.text ?? entry.message ?? ""),
    });
    if (ui.logs.length > 1000) {
      ui.logs.splice(0, ui.logs.length - 1000);
    }
  }

  function matchesLogFilter(entry) {
    if (ui.logCategory !== "all") {
      const cat = entry.category;
      if (ui.logCategory === "deploy" && !["deploy", "build", "engine", "proxy"].includes(cat)) return false;
      if (ui.logCategory === "colab" && !["colab", "auth", "attach"].includes(cat)) return false;
      if (ui.logCategory === "keepalive" && !["keepalive", "quota"].includes(cat)) return false;
      if (ui.logCategory === "cmd" && !["cmd", "exec", "diag"].includes(cat)) return false;
    }
    if (ui.logQuery) {
      const hay = `${entry.ts} ${entry.category} ${entry.text}`.toLowerCase();
      if (!hay.includes(ui.logQuery)) return false;
    }
    return true;
  }

  function renderLogs() {
    const container = $("logLinesContainer");
    const empty = $("logEmptyState");
    const viewport = $("logViewport");
    if (!container || !empty) return;

    const filtered = ui.logs.filter(matchesLogFilter);
    if (filtered.length === 0) {
      empty.classList.remove("hidden");
      empty.textContent =
        ui.logs.length === 0
          ? (ui.lang === "zh" ? "暂无日志，等待实时事件流..." : "Waiting for log stream...")
          : (ui.lang === "zh" ? "当前过滤条件下无匹配日志" : "No logs match current filter");
      container.innerHTML = "";
      return;
    }
    empty.classList.add("hidden");

    const frag = document.createDocumentFragment();
    filtered.forEach((entry) => {
      const row = document.createElement("div");
      row.className = `log-line log-line--${entry.level} log-line--${entry.category}`;

      const tsSpan = document.createElement("span");
      tsSpan.className = "log-ts";
      tsSpan.textContent = entry.ts;

      const catSpan = document.createElement("span");
      catSpan.className = "log-cat";
      catSpan.textContent = entry.category;

      const msgSpan = document.createElement("span");
      msgSpan.className = "log-msg";
      msgSpan.textContent = maskText(entry.text);

      row.appendChild(tsSpan);
      row.appendChild(catSpan);
      row.appendChild(msgSpan);
      frag.appendChild(row);
    });

    container.innerHTML = "";
    container.appendChild(frag);

    if (ui.autoScroll && viewport) {
      viewport.scrollTop = viewport.scrollHeight;
    }
  }

  async function loadInitialLogs() {
    try {
      const data = await apiRequest("/api/studio/logs", { timeoutMs: 8000 });
      const list = Array.isArray(data) ? data : (data.logs || data.items || []);
      list.forEach(appendLogEntry);
      renderLogs();
    } catch {
      // SSE stream will still populate when backend is ready
    }
  }

  function setSseBadge(status) {
    const badge = $("sseStatusBadge");
    const text = $("sseStatusText");
    if (!badge || !text) return;
    badge.classList.remove("sse-badge--live", "sse-badge--connecting");
    const dot = badge.querySelector(".dot");
    if (status === "live") {
      badge.classList.add("sse-badge--live");
      text.textContent = t("logs.live");
      if (dot) dot.className = "dot dot--green";
    } else if (status === "reconnecting") {
      badge.classList.add("sse-badge--connecting");
      text.textContent = t("logs.reconnecting");
      if (dot) dot.className = "dot dot--amber";
    } else {
      badge.classList.add("sse-badge--connecting");
      text.textContent = t("logs.connecting");
      if (dot) dot.className = "dot dot--amber";
    }
  }

  function connectLogStream() {
    if (ui.eventSource) {
      ui.eventSource.close();
      ui.eventSource = null;
    }
    setSseBadge("connecting");
    const es = new EventSource("/api/studio/logs/stream");
    ui.eventSource = es;

    es.onopen = () => {
      setSseBadge("live");
    };

    es.onmessage = (event) => {
      setSseBadge("live");
      if (!event.data) return;
      try {
        const parsed = JSON.parse(event.data);
        appendLogEntry(parsed);
        renderLogs();
      } catch {
        appendLogEntry({ category: "system", level: "info", text: event.data });
        renderLogs();
      }
    };

    es.onerror = () => {
      setSseBadge("reconnecting");
    };
  }

  async function pollStateOnce() {
    if (ui.pollInFlight) return;
    ui.pollInFlight = true;
    try {
      const state = await apiRequest("/api/studio/state", { timeoutMs: 8000 });
      renderState(state);
    } catch {
      // Keep quiet on transient background polls
    } finally {
      ui.pollInFlight = false;
      scheduleNextPoll();
    }
  }

  function scheduleNextPoll() {
    if (ui.pollTimer) clearTimeout(ui.pollTimer);
    const dep = ui.lastState?.deployment || {};
    const phase = String(dep.phase || "").toLowerCase();
    const active = Number(dep.step_index || 0) > 0 && phase !== "idle" && phase !== "ready" && phase !== "error";
    const interval = active ? 2000 : 3500;
    ui.pollTimer = setTimeout(pollStateOnce, interval);
  }

  async function refreshStateNow() {
    if (ui.pollTimer) clearTimeout(ui.pollTimer);
    await pollStateOnce();
  }

  function openModal(id) {
    $(id)?.classList.remove("hidden");
  }

  function closeModal(id) {
    $(id)?.classList.add("hidden");
  }

  function setModalFeedback(elId, msg, isErr = false) {
    const el = $(elId);
    if (!el) return;
    if (!msg) {
      el.classList.add("hidden");
      return;
    }
    el.textContent = msg;
    el.className = `modal-feedback ${isErr ? "modal-feedback--err" : "modal-feedback--ok"}`;
    el.classList.remove("hidden");
  }

  function collectSettingsPayload() {
    const hfRepo = $("hfRepoInput")?.value?.trim() || "";
    const s2Thresh = Number($("s2GcsThreshInput")?.value || 160);
    const s2Local = Number($("s2LocalMaxInput")?.value || 16);
    const contextLen = Number($("mayaContextSelect")?.value || 262144);
    const strataUrl = $("strataUrlInput")?.value?.trim() || "";
    const strataModel = $("strataModelInput")?.value?.trim() || "";
    const strataMaxCtx = Number($("strataMaxCtxInput")?.value || 65536);

    return {
      mask_urls: ui.privacyMask,
      hf_repo: hfRepo,
      s2_gcs_thresh: Number.isFinite(s2Thresh) ? s2Thresh : 160,
      s2_local_max: Number.isFinite(s2Local) ? s2Local : 16,
      max_context: contextLen,
      vision: ui.visionOn,
      vision_enabled: ui.visionOn,
      strata_url: strataUrl,
      strata_model: strataModel,
      strata_max_context: Number.isFinite(strataMaxCtx) ? strataMaxCtx : 65536,
    };
  }

  function switchTab(tabName) {
    ui.activeTab = tabName;
    document.querySelectorAll(".stage-tab").forEach((btn) => {
      const active = btn.dataset.tab === tabName;
      btn.classList.toggle("is-active", active);
      btn.setAttribute("aria-selected", active ? "true" : "false");
    });
    const map = {
      console: "tabPanelConsole",
      telemetry: "tabPanelTelemetry",
      clients: "tabPanelClients",
    };
    Object.entries(map).forEach(([k, panelId]) => {
      $(panelId)?.classList.toggle("is-active", k === tabName);
    });
  }

  function syncPrivacyButton() {
    const btn = $("btnPrivacyMask");
    const st = $("privacyMaskState");
    if (btn) {
      btn.classList.toggle("is-active", ui.privacyMask);
      btn.setAttribute("aria-pressed", ui.privacyMask ? "true" : "false");
    }
    if (st) {
      st.textContent = ui.privacyMask ? "ON" : "OFF";
    }
  }

  function bindEvents() {
    // Track dirty inputs so polling never overwrites active user typing
    [
      "sessionInput",
      "hfRepoInput",
      "s2GcsThreshInput",
      "s2LocalMaxInput",
      "strataUrlInput",
      "strataModelInput",
      "strataMaxCtxInput",
    ].forEach((id) => {
      const el = $(id);
      if (!el) return;
      el.addEventListener("input", () => ui.dirtyInputs.add(id));
    });

    // Topbar actions
    $("btnOpenGuide")?.addEventListener("click", () => openModal("guideModal"));

    const openProxyExternal = () => {
      if (!ui.lastState?.engine?.online) {
        showToast(
          ui.lang === "zh"
            ? "远端权重仍在装入中，新窗口就绪后将每 5 秒自动刷新进入控制台"
            : "Engine warming up; tab will auto-refresh every 5s",
          "warn"
        );
      }
      const url = `${getProxyBaseUrl()}/`;
      window.open(url, "_blank", "noopener");
    };

    $("btnOpenExternalWebui")?.addEventListener("click", openProxyExternal);

    $("btnFallbackNewTab")?.addEventListener("click", openProxyExternal);

    $("btnLangToggle")?.addEventListener("click", () => {
      ui.lang = ui.lang === "zh" ? "en" : "zh";
      localStorage.setItem("maya_studio_lang", ui.lang);
      applyI18n();
      renderMayaModes();
      if (ui.lastState) renderState(ui.lastState);
      renderLogs();
    });

    $("btnPrivacyMask")?.addEventListener("click", () => {
      ui.privacyMask = !ui.privacyMask;
      localStorage.setItem("maya_studio_privacy", String(ui.privacyMask));
      syncPrivacyButton();
      if (ui.lastState) renderState(ui.lastState);
      renderLogs();
      apiRequest("/api/studio/settings", {
        method: "POST",
        body: { mask_urls: ui.privacyMask },
      }).catch(() => {});
      showToast(
        ui.privacyMask
          ? (ui.lang === "zh" ? "已开启录屏隐私打码" : "Privacy mask enabled")
          : (ui.lang === "zh" ? "已关闭录屏隐私打码" : "Privacy mask disabled"),
        "ok"
      );
    });

    // GPU selector
    document.querySelectorAll("#gpuSelectGroup .gpu-option").forEach((btn) => {
      btn.addEventListener("click", () => {
        ui.selectedGpu = btn.dataset.gpu || "g4";
        renderGpuSelection();
      });
    });

    // Engine segment switch
    $("segEngineMaya")?.addEventListener("click", () => {
      ui.selectedEnginePanel = "maya";
      renderEngineSegment();
    });
    $("segEngineStrata")?.addEventListener("click", () => {
      ui.selectedEnginePanel = "strata";
      renderEngineSegment();
    });

    // Vision toggle
    $("btnVisionToggle")?.addEventListener("click", () => {
      ui.visionOn = !ui.visionOn;
      const btn = $("btnVisionToggle");
      const txt = $("visionToggleText");
      if (btn) {
        btn.classList.toggle("is-on", ui.visionOn);
        btn.setAttribute("aria-checked", ui.visionOn ? "true" : "false");
      }
      if (txt) txt.textContent = ui.visionOn ? "--vision on" : "--vision off";
    });

    // Colab Refresh
    $("btnColabRefresh")?.addEventListener("click", async () => {
      const btn = $("btnColabRefresh");
      setButtonBusy(btn, true, ui.lang === "zh" ? "刷新中..." : "...");
      try {
        await apiRequest("/api/studio/colab/refresh", { method: "POST", body: { session: getSessionValue() } });
        await refreshStateNow();
        showToast(ui.lang === "zh" ? "Colab 账号与算力额度已刷新" : "Colab status refreshed");
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "刷新失败" : "Refresh failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // Colab Deploy
    $("btnDeployColab")?.addEventListener("click", async () => {
      const btn = $("btnDeployColab");
      setButtonBusy(btn, true, ui.lang === "zh" ? "正在提交部署..." : "Deploying...");
      try {
        await apiRequest("/api/studio/colab/deploy", {
          method: "POST",
          body: {
            gpu: ui.selectedGpu,
            session: getSessionValue(),
            engine_kind: ui.selectedEnginePanel,
            mode: ui.selectedMode,
            settings: collectSettingsPayload(),
          },
          timeoutMs: 60000,
        });
        showToast(ui.lang === "zh" ? "已启动云端实例部署流水线" : "Deployment pipeline started");
        await refreshStateNow();
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "部署失败" : "Deploy failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // Colab Lossless Attach (left button & center shortcut)
    const doAttach = async (triggerBtn) => {
      setButtonBusy(triggerBtn, true, ui.lang === "zh" ? "只读探测纳管中..." : "Attaching...");
      try {
        const res = await apiRequest("/api/studio/colab/attach", {
          method: "POST",
          body: {
            session: getSessionValue(),
            engine_kind: ui.selectedEnginePanel,
          },
          timeoutMs: 60000,
        });
        ui.dirtyInputs.delete("sessionInput");
        await refreshStateNow();
        if (res?.keepalive_auto_started) {
          showToast(ui.lang === "zh" ? "已完成无损纳管，并自动恢复 12m 保活" : "Attached losslessly & restored 12m keepalive");
        } else {
          showToast(ui.lang === "zh" ? "已完成无损纳管并绑定本地代理" : "Attached losslessly");
        }
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "纳管失败" : "Attach failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(triggerBtn, false);
      }
    };

    $("btnAttachColab")?.addEventListener("click", () => doAttach($("btnAttachColab")));
    $("btnQuickAttachCenter")?.addEventListener("click", () => doAttach($("btnQuickAttachCenter")));

    $("btnQuickStrataCenter")?.addEventListener("click", () => {
      ui.selectedEnginePanel = "strata";
      renderEngineSegment();
      $("strataUrlInput")?.focus();
    });

    // Keepalive Toggle
    $("btnKeepaliveToggle")?.addEventListener("click", async () => {
      const currentlyOn = Boolean(ui.lastState?.colab?.keepalive_running);
      try {
        await apiRequest("/api/studio/colab/keepalive", {
          method: "POST",
          body: {
            enabled: !currentlyOn,
            session: getSessionValue(),
            interval_sec: 720,
          },
        });
        await refreshStateNow();
        showToast(
          !currentlyOn
            ? (ui.lang === "zh" ? "已开启 12 分钟自动保活" : "Keepalive enabled")
            : (ui.lang === "zh" ? "已停止本地保活守护" : "Keepalive stopped")
        );
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "保活切换失败" : "Keepalive error"}: ${err.message}`, "err");
      }
    });

    // Stop Colab (with secondary confirmation modal!)
    $("btnStopColab")?.addEventListener("click", () => {
      const display = $("stopSessionDisplay");
      if (display) display.textContent = getSessionValue();
      openModal("stopConfirmModal");
    });

    $("btnConfirmStop")?.addEventListener("click", async () => {
      const btn = $("btnConfirmStop");
      setButtonBusy(btn, true, ui.lang === "zh" ? "释放中..." : "Releasing...");
      try {
        await apiRequest("/api/studio/colab/stop", {
          method: "POST",
          body: {
            session: getSessionValue(),
            confirm: true,
          },
        });
        closeModal("stopConfirmModal");
        await refreshStateNow();
        showToast(ui.lang === "zh" ? "已发送实例释放指令" : "Instance release requested", "warn");
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "释放失败" : "Stop failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // Save Maya advanced config
    $("btnApplyMayaConfig")?.addEventListener("click", async () => {
      const btn = $("btnApplyMayaConfig");
      setButtonBusy(btn, true, ui.lang === "zh" ? "保存中..." : "Saving...");
      try {
        const settings = collectSettingsPayload();
        await apiRequest("/api/studio/engine/configure", {
          method: "POST",
          body: {
            kind: "maya",
            mode: ui.selectedMode,
            upstream_url: ui.lastState?.engine?.upstream_url || "",
            settings,
          },
        });
        ui.dirtyInputs.delete("hfRepoInput");
        ui.dirtyInputs.delete("s2GcsThreshInput");
        ui.dirtyInputs.delete("s2LocalMaxInput");
        await refreshStateNow();
        showToast(ui.lang === "zh" ? "Maya 引擎配置已保存" : "Maya config saved");
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "保存失败" : "Save failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // Connect Strata Node
    $("btnConnectStrata")?.addEventListener("click", async () => {
      const url = $("strataUrlInput")?.value?.trim();
      if (!url) {
        showToast(ui.lang === "zh" ? "请输入 Strata 节点地址 (Upstream URL)" : "Enter Strata node URL", "warn");
        $("strataUrlInput")?.focus();
        return;
      }
      const btn = $("btnConnectStrata");
      setButtonBusy(btn, true, ui.lang === "zh" ? "挂载中..." : "Mounting...");
      try {
        const apiKey = $("strataApiKeyInput")?.value || "";
        const settings = collectSettingsPayload();
        await apiRequest("/api/studio/engine/configure", {
          method: "POST",
          body: {
            kind: "strata",
            mode: "strata_direct",
            upstream_url: url,
            api_key: apiKey,
            settings,
          },
        });
        ui.dirtyInputs.delete("strataUrlInput");
        ui.dirtyInputs.delete("strataModelInput");
        ui.dirtyInputs.delete("strataMaxCtxInput");
        if ($("strataApiKeyInput")) $("strataApiKeyInput").value = "";
        ui.currentUpstreamKey = ""; // Force iframe reload for new Strata node
        await refreshStateNow();
        showToast(ui.lang === "zh" ? "Strata 节点已挂载至本地代理" : "Strata node mounted");
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "Strata 挂载失败" : "Strata connect failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // OAuth Modal
    const fetchAuthUrl = async () => {
      const btn = $("btnFetchAuthUrl");
      setButtonBusy(btn, true, ui.lang === "zh" ? "生成中..." : "Generating...");
      setModalFeedback("authModalFeedback", "");
      try {
        const data = await apiRequest("/api/studio/colab/auth-url", { method: "POST", body: {} });
        const url = data.url || data.auth_url || "";
        if (!url) throw new Error("后端未返回授权链接");
        $("oauthUrlDisplay").value = url;
        $("btnOpenAuthUrl").disabled = false;
        $("btnCopyAuthUrl").disabled = false;
        setModalFeedback("authModalFeedback", ui.lang === "zh" ? "已生成授权链接，请打开完成 Google 登录并粘贴回调结果。" : "Auth URL ready.");
      } catch (err) {
        setModalFeedback("authModalFeedback", err.message, true);
      } finally {
        setButtonBusy(btn, false);
      }
    };

    $("btnOpenAuthModal")?.addEventListener("click", () => {
      setModalFeedback("authModalFeedback", "");
      openModal("authModal");
      if (!$("oauthUrlDisplay")?.value) {
        fetchAuthUrl();
      }
    });

    $("btnFetchAuthUrl")?.addEventListener("click", fetchAuthUrl);

    $("btnOpenAuthUrl")?.addEventListener("click", () => {
      const url = $("oauthUrlDisplay")?.value;
      if (url) window.open(url, "_blank", "noopener");
    });

    $("btnCopyAuthUrl")?.addEventListener("click", () => {
      copyToClipboard($("oauthUrlDisplay")?.value, "OAuth URL");
    });

    $("btnSubmitAuthCode")?.addEventListener("click", async () => {
      const code = $("oauthCodeInput")?.value?.trim();
      if (!code) {
        setModalFeedback("authModalFeedback", ui.lang === "zh" ? "请先粘贴授权码或回调 URL" : "Paste code or callback URL", true);
        return;
      }
      const btn = $("btnSubmitAuthCode");
      setButtonBusy(btn, true, ui.lang === "zh" ? "验证中..." : "Verifying...");
      try {
        await apiRequest("/api/studio/colab/auth-code", {
          method: "POST",
          body: { code, redirect_url: code },
        });
        $("oauthCodeInput").value = "";
        setModalFeedback("authModalFeedback", ui.lang === "zh" ? "授权成功！" : "Authorized!");
        await refreshStateNow();
        setTimeout(() => closeModal("authModal"), 700);
      } catch (err) {
        setModalFeedback("authModalFeedback", err.message, true);
      } finally {
        setButtonBusy(btn, false);
      }
    });

    $("btnAuthLogout")?.addEventListener("click", async () => {
      const btn = $("btnAuthLogout");
      setButtonBusy(btn, true, ui.lang === "zh" ? "退出中..." : "Signing out...");
      try {
        await apiRequest("/api/studio/colab/auth-logout", { method: "POST", body: {} });
        await refreshStateNow();
        setModalFeedback("authModalFeedback", ui.lang === "zh" ? "已退出当前 Google 账号" : "Signed out");
      } catch (err) {
        setModalFeedback("authModalFeedback", err.message, true);
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // Credentials Modal
    $("btnOpenCredentials")?.addEventListener("click", () => {
      setModalFeedback("credModalFeedback", "");
      if ($("chkClearMayaKey")) $("chkClearMayaKey").checked = false;
      openModal("credentialsModal");
    });

    const generateRandomMayaKey = () => {
      const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
      const bytes = new Uint8Array(32);
      if (window.crypto && typeof window.crypto.getRandomValues === "function") {
        window.crypto.getRandomValues(bytes);
      } else {
        for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(Math.random() * 256);
      }
      let out = "sk-maya-";
      for (let i = 0; i < bytes.length; i += 1) {
        out += alphabet[bytes[i] % alphabet.length];
      }
      return out;
    };

    $("btnGenMayaKey")?.addEventListener("click", () => {
      const key = generateRandomMayaKey();
      if ($("credMayaKeyInput")) $("credMayaKeyInput").value = key;
      if ($("chkClearMayaKey")) $("chkClearMayaKey").checked = false;
      setModalFeedback(
        "credModalFeedback",
        ui.lang === "zh"
          ? "已生成高强度随机网关密钥（已隐码填入），点击“安全保存凭据”写入 ~/.config/maya-gcs/maya-api-key"
          : "Generated random gateway key; click Save Securely to persist."
      );
    });

    $("btnCopyMayaKey")?.addEventListener("click", () => {
      const val = $("credMayaKeyInput")?.value?.trim();
      if (!val) {
        showToast(ui.lang === "zh" ? "输入框为空，请先输入或点击“随机生成”" : "Input is empty", "warn");
        return;
      }
      copyToClipboard(val, "Maya API Key");
    });

    $("chkClearMayaKey")?.addEventListener("change", (e) => {
      if (e.target?.checked && $("credMayaKeyInput")) {
        $("credMayaKeyInput").value = "";
      }
    });

    $("credGcsKeyFile")?.addEventListener("change", async (e) => {
      const file = e.target?.files?.[0];
      if (!file) return;
      try {
        const text = await file.text();
        if ($("credGcsKeyInput")) $("credGcsKeyInput").value = text.trim();
        setModalFeedback("credModalFeedback", ui.lang === "zh" ? `已读取本地文件 ${file.name}，点击“安全保存凭据”生效` : `Loaded ${file.name}`);
      } catch (err) {
        setModalFeedback("credModalFeedback", err.message, true);
      } finally {
        e.target.value = "";
      }
    });

    $("btnSaveCredentials")?.addEventListener("click", async () => {
      const btn = $("btnSaveCredentials");
      const payload = {};
      const hfToken = $("credHfTokenInput")?.value?.trim();
      const bucket = $("credBucketInput")?.value?.trim();
      const gcsKey = $("credGcsKeyInput")?.value?.trim();
      const mayaKey = $("credMayaKeyInput")?.value?.trim();
      const clearMayaKey = Boolean($("chkClearMayaKey")?.checked);
      const strataKey = $("credStrataKeyInput")?.value?.trim();
      if (hfToken) payload.hf_token = hfToken;
      if (bucket) payload.gcs_bucket = bucket;
      if (gcsKey) payload.gcs_key_json = gcsKey;
      if (clearMayaKey) {
        payload.clear_maya_api_key = true;
      } else if (mayaKey) {
        payload.maya_api_key = mayaKey;
      }
      if (strataKey) payload.strata_api_key = strataKey;

      if (Object.keys(payload).length === 0) {
        setModalFeedback("credModalFeedback", ui.lang === "zh" ? "未填写任何需要更新的凭据字段" : "No fields entered to update", true);
        return;
      }

      setButtonBusy(btn, true, ui.lang === "zh" ? "写入中..." : "Saving...");
      try {
        await apiRequest("/api/studio/credentials", { method: "POST", body: payload });
        $("credHfTokenInput").value = "";
        $("credBucketInput").value = "";
        $("credGcsKeyInput").value = "";
        if ($("credMayaKeyInput")) $("credMayaKeyInput").value = "";
        if ($("chkClearMayaKey")) $("chkClearMayaKey").checked = false;
        $("credStrataKeyInput").value = "";
        await refreshStateNow();
        setModalFeedback("credModalFeedback", ui.lang === "zh" ? "凭据已按 0600 权限安全保存" : "Credentials saved securely");
        setTimeout(() => closeModal("credentialsModal"), 700);
      } catch (err) {
        setModalFeedback("credModalFeedback", err.message, true);
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // Close modals via [data-close-modal] or backdrop click / Escape
    document.querySelectorAll("[data-close-modal]").forEach((btn) => {
      btn.addEventListener("click", () => closeModal(btn.getAttribute("data-close-modal")));
    });
    document.querySelectorAll(".modal-backdrop").forEach((backdrop) => {
      backdrop.addEventListener("click", (e) => {
        if (e.target === backdrop) backdrop.classList.add("hidden");
      });
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        document.querySelectorAll(".modal-backdrop:not(.hidden)").forEach((m) => m.classList.add("hidden"));
      }
    });

    // Stage Tabs
    document.querySelectorAll(".stage-tab").forEach((tabBtn) => {
      tabBtn.addEventListener("click", () => switchTab(tabBtn.dataset.tab || "console"));
    });

    // Copy Address Pills (decoupled from privacy mask: clipboard always receives real unmasked URL)
    $("btnCopyUpstream")?.addEventListener("click", () => {
      const up = ui.lastState?.engine?.upstream_url || "";
      copyToClipboard(up, ui.lang === "zh" ? "上游地址" : "Upstream URL");
    });

    $("btnCopyProxy")?.addEventListener("click", () => {
      copyToClipboard(getOpenAIBaseUrl(), ui.lang === "zh" ? "本地网关地址" : "Gateway URL");
    });

    // Reload Iframe
    $("btnReloadIframe")?.addEventListener("click", () => {
      const proxyBase = getProxyBaseUrl();
      if (ui.lastState?.engine?.online) {
        loadIframeTarget(`${proxyBase}/`);
        showToast(ui.lang === "zh" ? "正在刷新内嵌控制台" : "Reloading embedded console");
      } else {
        refreshStateNow();
      }
    });

    $("engineWebuiFrame")?.addEventListener("load", () => {
      if (ui.iframeLoadTimer) clearTimeout(ui.iframeLoadTimer);
      $("iframeLoadingChip")?.classList.add("hidden");
    });

    // Sync Clients to Pi
    const runSyncPi = async (triggerBtn) => {
      setButtonBusy(triggerBtn, true, ui.lang === "zh" ? "同步中..." : "Syncing...");
      try {
        const useLocal = $("chkUseLocalProxy") ? $("chkUseLocalProxy").checked : true;
        const data = await apiRequest("/api/studio/engine/sync-clients", {
          method: "POST",
          body: { target: "pi", use_local_proxy: useLocal },
        });
        if (data.snippets) {
          if (data.snippets.pi && $("snippetPi")) $("snippetPi").textContent = maskText(data.snippets.pi);
          if (data.snippets.cursor && $("snippetCursor")) $("snippetCursor").textContent = maskText(data.snippets.cursor);
          if (data.snippets.claude_code && $("snippetClaude")) $("snippetClaude").textContent = maskText(data.snippets.claude_code);
          if (data.snippets.openai_python && $("snippetOpenai")) $("snippetOpenai").textContent = maskText(data.snippets.openai_python);
          const hasMaskedTunnel = String(data.snippets.pi || "").includes("******.trycloudflare.com");
          if (useLocal || !hasMaskedTunnel) {
            ui.rawSnippets = {
              pi: data.snippets.pi || ui.rawSnippets.pi,
              cursor: data.snippets.cursor || ui.rawSnippets.cursor,
              claude: data.snippets.claude_code || ui.rawSnippets.claude,
              openai: data.snippets.openai_python || ui.rawSnippets.openai,
            };
          }
        }
        const box = $("piSyncResultBox");
        if (box) {
          const msg = data.message || (ui.lang === "zh" ? "同步完成" : "Synced");
          const details = data.updated_files && data.updated_files.length ? ` (${Array.isArray(data.updated_files) ? data.updated_files.join(", ") : data.updated_files})` : "";
          box.innerHTML = `<span style="color:#6EE7B7;font-weight:600;">✓ ${escapeHtml(msg + details)}</span>`;
        }
        showToast(ui.lang === "zh" ? "已同步模型配置至 Pi" : "Synced config to Pi");
        await refreshStateNow();
      } catch (err) {
        const box = $("piSyncResultBox");
        if (box) {
          box.innerHTML = `<span style="color:#FCA5A5;">✕ ${escapeHtml(err.message)}</span>`;
        }
        showToast(`${ui.lang === "zh" ? "Pi 同步失败" : "Sync failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(triggerBtn, false);
      }
    };

    $("btnSyncPiQuick")?.addEventListener("click", () => runSyncPi($("btnSyncPiQuick")));
    $("btnSyncPiPanel")?.addEventListener("click", () => runSyncPi($("btnSyncPiPanel")));
    $("chkUseLocalProxy")?.addEventListener("change", () => renderSnippets(ui.lastState));

    // Copy Snippets (decoupled from privacy mask: prefer unmasked rawSnippets)
    document.querySelectorAll(".copy-snippet-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        const type = btn.dataset.snippet;
        const map = { pi: "snippetPi", cursor: "snippetCursor", claude: "snippetClaude", openai: "snippetOpenai" };
        const el = $(map[type]);
        const text = (type && ui.rawSnippets && ui.rawSnippets[type]) || el?.textContent || "";
        copyToClipboard(text, type?.toUpperCase());
      });
    });

    // Chat Probe
    $("btnRunProbe")?.addEventListener("click", async () => {
      const prompt = $("probePromptInput")?.value?.trim();
      if (!prompt) {
        showToast(ui.lang === "zh" ? "请输入探针提示词" : "Enter prompt", "warn");
        return;
      }
      const maxTokens = Number($("probeMaxTokens")?.value || 128);
      const btn = $("btnRunProbe");
      setButtonBusy(btn, true, ui.lang === "zh" ? "探测中..." : "Probing...");
      try {
        const data = await apiRequest("/api/studio/engine/probe", {
          method: "POST",
          body: { prompt, max_tokens: maxTokens },
          timeoutMs: 120000,
        });
        const latencyMs = data.latency_ms ?? data.elapsed_ms ?? "--";
        const badge = $("probeLatencyBadge");
        if (badge) badge.textContent = `${latencyMs} ms`;

        const outBox = $("probeOutputBox");
        const outMeta = $("probeOutputMeta");
        const outText = $("probeOutputText");
        if (outBox && outMeta && outText) {
          outBox.classList.remove("hidden");
          const parts = [];
          if (latencyMs !== "--") parts.push(`latency=${latencyMs}ms`);
          const compTokens = data.completion_tokens ?? data.usage?.completion_tokens;
          if (compTokens != null) parts.push(`tokens=${compTokens}`);
          const tokSpeed = data.decode_tok_s ?? data.tok_s;
          if (tokSpeed != null) parts.push(`speed=${Number(tokSpeed).toFixed(1)} tok/s`);
          if (data.model) parts.push(`model=${data.model}`);
          outMeta.textContent = parts.join(" · ") || "OK";
          const replyText = data.reply ?? data.content ?? data.text ?? "";
          const reasoningText = data.reasoning || "";
          if (replyText && reasoningText) {
            outText.textContent = `${replyText}\n\n[Thinking]\n${reasoningText}`;
          } else if (replyText) {
            outText.textContent = replyText;
          } else if (reasoningText) {
            outText.textContent = `[Thinking]\n${reasoningText}`;
          } else {
            outText.textContent = JSON.stringify(data, null, 2);
          }
        }
        await refreshStateNow();
      } catch (err) {
        showToast(`${ui.lang === "zh" ? "探针请求失败" : "Probe failed"}: ${err.message}`, "err");
      } finally {
        setButtonBusy(btn, false);
      }
    });

    // Right Column: Logs Filter & Controls
    document.querySelectorAll("#logCategoryPills .filter-pill").forEach((pill) => {
      pill.addEventListener("click", () => {
        ui.logCategory = pill.dataset.cat || "all";
        document.querySelectorAll("#logCategoryPills .filter-pill").forEach((p) => {
          p.classList.toggle("is-active", p === pill);
        });
        renderLogs();
      });
    });

    $("logSearchInput")?.addEventListener("input", (e) => {
      ui.logQuery = String(e.target.value || "").trim().toLowerCase();
      renderLogs();
    });

    $("btnAutoScroll")?.addEventListener("click", () => {
      ui.autoScroll = !ui.autoScroll;
      $("btnAutoScroll")?.classList.toggle("is-toggled", ui.autoScroll);
      if (ui.autoScroll) {
        const vp = $("logViewport");
        if (vp) vp.scrollTop = vp.scrollHeight;
      }
    });

    $("btnCopyLogs")?.addEventListener("click", () => {
      const text = ui.logs
        .filter(matchesLogFilter)
        .map((e) => `[${e.ts}] [${e.category}] ${maskText(e.text)}`)
        .join("\n");
      copyToClipboard(text, ui.lang === "zh" ? "日志" : "Logs");
    });

    $("btnClearLogs")?.addEventListener("click", () => {
      ui.logs = [];
      renderLogs();
    });

    // Diagnostic Chips & Custom Command Execution
    const execCommand = async (preset, command = "", triggerBtn = null) => {
      const statusEl = $("cmdExecStatus");
      if (triggerBtn) setButtonBusy(triggerBtn, true);
      if (statusEl) statusEl.textContent = ui.lang === "zh" ? "执行中..." : "Running...";
      try {
        const data = await apiRequest("/api/studio/cmd/exec", {
          method: "POST",
          body: {
            preset,
            command,
            session: getSessionValue(),
          },
          timeoutMs: 60000,
        });
        if (statusEl) statusEl.textContent = ui.lang === "zh" ? "已完成 ✓" : "Done ✓";
        if (data.output && ui.logs.length === 0) {
          appendLogEntry({ category: "cmd", level: "info", text: data.output });
          renderLogs();
        }
        setTimeout(() => {
          if (statusEl) statusEl.textContent = "";
        }, 2500);
      } catch (err) {
        if (statusEl) statusEl.textContent = "";
        showToast(`${ui.lang === "zh" ? "命令执行失败" : "Command failed"}: ${err.message}`, "err");
      } finally {
        if (triggerBtn) setButtonBusy(triggerBtn, false);
      }
    };

    document.querySelectorAll(".diag-chip").forEach((chip) => {
      chip.addEventListener("click", () => {
        execCommand(chip.dataset.preset || "nvidia_smi", "", chip);
      });
    });

    $("customCmdForm")?.addEventListener("submit", async (e) => {
      e.preventDefault();
      const input = $("customCmdInput");
      const cmd = input?.value?.trim();
      if (!cmd) return;
      input.value = "";
      await execCommand("custom", cmd, $("btnRunCustomCmd"));
    });
  }

  async function init() {
    const params = new URLSearchParams(window.location.search);
    if (params.get("shell") === "macos") {
      document.body.classList.add("shell-macos");
    }

    syncPrivacyButton();
    applyI18n();
    renderGpuSelection();
    renderEngineSegment();
    renderMayaModes();
    renderDeploySteps({}, false);
    renderSnippets(null);
    bindEvents();

    if (!ui.elapsedTicker) {
      ui.elapsedTicker = setInterval(() => {
        if (!ui.lastState) return;
        const eng = ui.lastState.engine || {};
        const dep = ui.lastState.deployment || {};
        const engReady = Boolean(eng.online) && eng.loaded !== false;
        const ph = String(dep.phase || "idle").toLowerCase();
        if (!engReady && ph !== "idle" && ph !== "ready" && ph !== "error") {
          const text = buildEtaSummary(dep, false);
          if ($("deployEtaText")) $("deployEtaText").textContent = text;
          if ($("rightProgressEta")) $("rightProgressEta").textContent = text;
        }
      }, 1000);
    }

    await pollStateOnce();
    await loadInitialLogs();
    connectLogStream();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
