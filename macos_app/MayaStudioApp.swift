import AppKit
import Darwin
import Foundation
import WebKit

// MARK: - Application Entry Point

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var studioController: StudioWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let controller = StudioWindowController()
        self.studioController = controller
        self.mainWindow = controller.window

        controller.showWindow(nil)
        controller.start()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        studioController?.terminateOwnedBackendIfNeeded()
    }

    // MARK: - Native Menu Bar (Essential for Cmd+C / Cmd+V / Cmd+X / Cmd+A / Cmd+Z in WKWebView)

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Maya · Strata Studio")
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            withTitle: "关于 Maya · Strata Studio",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 Maya · Strata Studio",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthersItem = appMenu.addItem(
            withTitle: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 Maya · Strata Studio",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu

        let reloadItem = fileMenu.addItem(
            withTitle: "重新加载工作台",
            action: #selector(StudioWindowController.reloadConsole(_:)),
            keyEquivalent: "r"
        )
        reloadItem.target = nil

        let openExternalItem = fileMenu.addItem(
            withTitle: "在默认浏览器中打开",
            action: #selector(StudioWindowController.openCurrentInBrowser(_:)),
            keyEquivalent: "o"
        )
        openExternalItem.keyEquivalentModifierMask = [.command, .shift]
        openExternalItem.target = nil

        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        // 3. Edit Menu (Responder chain routes directly to WKWebView)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 4. View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "视图")
        viewMenuItem.submenu = viewMenu

        let zoomResetItem = viewMenu.addItem(
            withTitle: "实际大小",
            action: #selector(StudioWindowController.resetPageZoom(_:)),
            keyEquivalent: "0"
        )
        zoomResetItem.target = nil

        let zoomInItem = viewMenu.addItem(
            withTitle: "放大",
            action: #selector(StudioWindowController.zoomInPage(_:)),
            keyEquivalent: "="
        )
        zoomInItem.target = nil

        let zoomOutItem = viewMenu.addItem(
            withTitle: "缩小",
            action: #selector(StudioWindowController.zoomOutPage(_:)),
            keyEquivalent: "-"
        )
        zoomOutItem.target = nil

        viewMenu.addItem(.separator())
        let fullScreenItem = viewMenu.addItem(
            withTitle: "进入全屏",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]

        // 5. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "前置全部窗口",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
    }
}

// MARK: - Window Drag Strip (Reserved over traffic-light gutter only)

private final class TitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - Native Background Sound Alert Synthesizer (Works even when app is hidden/minimized)

@MainActor
private final class StudioSoundPlayer: NSObject, NSSoundDelegate {
    private struct Note {
        let freq: Double
        let start: Double
        let duration: Double
        let gain: Double
        let harmonic: Double
    }

    private var activeSounds: [NSSound] = []
    private var lastPlayedAt: [String: Date] = [:]
    private var cachedWavs: [String: Data] = [:]

    func play(kind: String) {
        let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        if normalized != "test", let prev = lastPlayedAt[normalized], now.timeIntervalSince(prev) < 1.5 {
            return
        }
        lastPlayedAt[normalized] = now

        let wavData = cachedWavs[normalized] ?? buildWav(for: normalized)
        cachedWavs[normalized] = wavData
        guard let sound = NSSound(data: wavData) else {
            NSSound.beep()
            return
        }
        sound.volume = 0.85
        sound.delegate = self
        activeSounds.append(sound)
        sound.play()
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor [weak self] in
            self?.activeSounds.removeAll { $0 === sound }
        }
    }

    private func buildWav(for kind: String) -> Data {
        let notes: [Note]
        switch kind {
        case "gpu_ready":
            // Bright celebratory triad arpeggio: C5 -> E5 -> G5 (with gentle shimmer)
            notes = [
                Note(freq: 523.25, start: 0.00, duration: 0.14, gain: 0.28, harmonic: 0.22),
                Note(freq: 659.25, start: 0.11, duration: 0.15, gain: 0.30, harmonic: 0.24),
                Note(freq: 783.99, start: 0.22, duration: 0.34, gain: 0.34, harmonic: 0.26),
                Note(freq: 1046.50, start: 0.24, duration: 0.32, gain: 0.14, harmonic: 0.10),
            ]
        case "engine_online":
            // Full celebratory fanfare: C5 -> E5 -> G5 -> C6
            notes = [
                Note(freq: 523.25, start: 0.00, duration: 0.13, gain: 0.26, harmonic: 0.20),
                Note(freq: 659.25, start: 0.10, duration: 0.13, gain: 0.28, harmonic: 0.22),
                Note(freq: 783.99, start: 0.20, duration: 0.15, gain: 0.30, harmonic: 0.24),
                Note(freq: 1046.50, start: 0.31, duration: 0.44, gain: 0.35, harmonic: 0.26),
                Note(freq: 523.25, start: 0.31, duration: 0.42, gain: 0.14, harmonic: 0.10),
            ]
        case "error":
            // Clear, noticeable two-pulse alert: E4 -> C4 repeated once
            notes = [
                Note(freq: 329.63, start: 0.00, duration: 0.16, gain: 0.34, harmonic: 0.28),
                Note(freq: 261.63, start: 0.17, duration: 0.22, gain: 0.36, harmonic: 0.30),
                Note(freq: 329.63, start: 0.44, duration: 0.16, gain: 0.34, harmonic: 0.28),
                Note(freq: 261.63, start: 0.61, duration: 0.28, gain: 0.38, harmonic: 0.32),
            ]
        default:
            // Soft test/confirmation chime: E5 -> G5
            notes = [
                Note(freq: 659.25, start: 0.00, duration: 0.12, gain: 0.25, harmonic: 0.20),
                Note(freq: 783.99, start: 0.10, duration: 0.24, gain: 0.28, harmonic: 0.22),
            ]
        }
        return synthesizeWav(notes: notes, sampleRate: 44100)
    }

    private func synthesizeWav(notes: [Note], sampleRate: Int) -> Data {
        let totalSec = (notes.map { $0.start + $0.duration }.max() ?? 0.3) + 0.04
        let sampleCount = max(1, Int(totalSec * Double(sampleRate)))
        var mix = [Double](repeating: 0.0, count: sampleCount)
        let twoPi = 2.0 * Double.pi

        for note in notes {
            let startIdx = max(0, Int(note.start * Double(sampleRate)))
            let len = max(1, Int(note.duration * Double(sampleRate)))
            let endIdx = min(sampleCount, startIdx + len)
            let attackSamples = max(1.0, 0.012 * Double(sampleRate))

            for idx in startIdx..<endIdx {
                let local = Double(idx - startIdx)
                let t = local / Double(sampleRate)
                let envAttack = min(1.0, local / attackSamples)
                let progress = local / Double(len)
                let envDecay = pow(max(0.0, 1.0 - progress), 1.45)
                let env = envAttack * envDecay
                let fundamental = sin(twoPi * note.freq * t)
                let overtone = note.harmonic * sin(twoPi * (note.freq * 2.0) * t)
                mix[idx] += note.gain * env * (fundamental + overtone)
            }
        }

        let dataByteCount = sampleCount * 2
        var wav = Data(capacity: 44 + dataByteCount)

        func appendASCII(_ s: String) {
            wav.append(contentsOf: s.utf8)
        }
        func appendLE<T: FixedWidthInteger>(_ val: T) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE(UInt32(36 + dataByteCount))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))         // PCM chunk size
        appendLE(UInt16(1))          // AudioFormat = PCM
        appendLE(UInt16(1))          // NumChannels = Mono
        appendLE(UInt32(sampleRate)) // SampleRate
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))          // BlockAlign
        appendLE(UInt16(16))         // BitsPerSample
        appendASCII("data")
        appendLE(UInt32(dataByteCount))

        for sample in mix {
            let clamped = max(-0.95, min(0.95, sample))
            appendLE(Int16(clamped * 32767.0))
        }
        return wav
    }
}

// MARK: - Main Studio Window Controller

@MainActor
final class StudioWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private static let bgColor = NSColor(srgbRed: 0x0B / 255.0, green: 0x0F / 255.0, blue: 0x17 / 255.0, alpha: 1.0)
    private static let cardColor = NSColor(srgbRed: 0x11 / 255.0, green: 0x18 / 255.0, blue: 0x26 / 255.0, alpha: 1.0)
    private static let accentColor = NSColor(srgbRed: 0x25 / 255.0, green: 0x63 / 255.0, blue: 0xEB / 255.0, alpha: 1.0)

    private let studioHost: String
    private let studioPort: Int
    private let proxyPort: Int

    private var webView: WKWebView!
    private var overlayView: NSView!
    private var spinner: NSProgressIndicator!
    private var statusTitleLabel: NSTextField!
    private var statusDetailLabel: NSTextField!
    private var errorScrollView: NSScrollView!
    private var errorTextView: NSTextView!
    private var retryButton: NSButton!
    private var openRootButton: NSButton!
    private var quitButton: NSButton!

    private var spawnedBackendProcess: Process?
    private var resolvedStudioRoot: String?
    private var outputBuffer = ""
    private var startupAttemptId = 0
    private var activeDownloads: [ObjectIdentifier: URL] = [:]
    private let soundPlayer = StudioSoundPlayer()
    private var backgroundActivity: NSObjectProtocol?

    private var studioURL: URL {
        URL(string: "http://\(studioHost):\(studioPort)/?shell=macos")!
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        self.studioHost = (env["MAYA_STUDIO_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        self.studioPort = Int(env["MAYA_STUDIO_PORT"] ?? "") ?? 18765
        self.proxyPort = Int(env["MAYA_PROXY_PORT"] ?? "") ?? 18766

        let frame = NSRect(x: 0, y: 0, width: 1480, height: 900)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Maya · Strata Studio"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Self.bgColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1260, height: 800)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        setupContentHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Construction

    private func setupContentHierarchy() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Self.bgColor.cgColor

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.websiteDataStore = .default()
        config.userContentController.add(self, name: "studioSound")

        let wv = WKWebView(frame: contentView.bounds, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = Self.bgColor
        }
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        self.webView = wv

        contentView.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            wv.topAnchor.constraint(equalTo: contentView.topAnchor),
            wv.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Native drag strip strictly confined to the top-left 78x40 traffic-light gutter
        let dragStrip = TitlebarDragView(frame: .zero)
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dragStrip)
        NSLayoutConstraint.activate([
            dragStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dragStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            dragStrip.widthAnchor.constraint(equalToConstant: 78),
            dragStrip.heightAnchor.constraint(equalToConstant: 40),
        ])

        setupLoadingOverlay(in: contentView)
    }

    private func setupLoadingOverlay(in container: NSView) {
        let overlay = NSView(frame: container.bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = Self.bgColor.cgColor
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.overlayView = overlay

        let card = NSView(frame: .zero)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = Self.cardColor.cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(srgbRed: 148 / 255.0, green: 163 / 255.0, blue: 184 / 255.0, alpha: 0.16).cgColor
        overlay.addSubview(card)

        let badge = NSTextField(labelWithString: "MAYA · STRATA STUDIO")
        badge.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = NSColor(srgbRed: 96 / 255.0, green: 165 / 255.0, blue: 250 / 255.0, alpha: 1.0)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false

        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .regular
        spin.appearance = NSAppearance(named: .darkAqua)
        spin.translatesAutoresizingMaskIntoConstraints = false
        self.spinner = spin

        let titleLabel = NSTextField(labelWithString: "正在连接本地控制面…")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = NSColor.white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.statusTitleLabel = titleLabel

        let detailLabel = NSTextField(wrappingLabelWithString: "控制台 \(studioHost):\(studioPort) · 代理网关 \(studioHost):\(proxyPort)")
        detailLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = NSColor(srgbRed: 148 / 255.0, green: 163 / 255.0, blue: 184 / 255.0, alpha: 1.0)
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        self.statusDetailLabel = detailLabel

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 0x07 / 255.0, green: 0x0A / 255.0, blue: 0x10 / 255.0, alpha: 1.0)
        scroll.isHidden = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = NSColor(srgbRed: 248 / 255.0, green: 180 / 255.0, blue: 180 / 255.0, alpha: 1.0)
        scroll.documentView = textView
        self.errorScrollView = scroll
        self.errorTextView = textView

        let retryBtn = NSButton(title: "重试连接", target: self, action: #selector(retryStartup(_:)))
        retryBtn.bezelStyle = .rounded
        retryBtn.contentTintColor = .white
        retryBtn.wantsLayer = true
        retryBtn.isHidden = true
        self.retryButton = retryBtn

        let openBtn = NSButton(title: "定位工作目录", target: self, action: #selector(revealStudioRoot(_:)))
        openBtn.bezelStyle = .rounded
        openBtn.isHidden = true
        self.openRootButton = openBtn

        let quitBtn = NSButton(title: "退出应用", target: self, action: #selector(quitApp(_:)))
        quitBtn.bezelStyle = .rounded
        quitBtn.isHidden = true
        self.quitButton = quitBtn

        let buttonRow = NSStackView(views: [retryBtn, openBtn, quitBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [badge, spin, titleLabel, detailLabel, scroll, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 560),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),

            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            scroll.widthAnchor.constraint(equalToConstant: 500),
            scroll.heightAnchor.constraint(equalToConstant: 150),
        ])
    }

    // MARK: - Startup & Backend Lifecycle

    func start() {
        if backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Keep Maya Strata Studio polling and audio alerts active in background"
            )
        }
        startupAttemptId += 1
        let attempt = startupAttemptId
        showLoadingState(
            title: "正在探测本地控制面服务…",
            detail: "检查 http://\(studioHost):\(studioPort) 是否已在运行（不干扰外部进程）"
        )

        Task { @MainActor [weak self] in
            let listening = await Task.detached { [studioHost, studioPort] in
                Self.isTCPPortListening(host: studioHost, port: studioPort)
            }.value
            guard let self, self.startupAttemptId == attempt else { return }
            if listening {
                self.showLoadingState(
                    title: "检测到已有 Studio 服务，正在复用接入…",
                    detail: "连接 http://\(studioHost):\(studioPort)/?shell=macos"
                )
                self.waitForHTTPAndLoad(attempt: attempt, timeoutSeconds: 8.0)
            } else {
                self.launchManagedBackend(attempt: attempt)
            }
        }
    }

    private func launchManagedBackend(attempt: Int) {
        guard let rootDir = resolvePortableStudioRoot() else {
            showErrorState(
                title: "未找到 Studio 服务目录",
                detail: "无法定位包含 studio/__main__.py 的工作目录。",
                diagnostics: """
                请确认以下任一条件成立：
                1. 将 MayaStudio.app 放在仓库根目录，或设置环境变量 MAYA_STUDIO_ROOT 指向仓库根目录；
                2. 或通过 bash macos_app/build_macos_app.sh 重新打包，将 studio/ 完整内嵌至 App Resources。
                """
            )
            return
        }
        self.resolvedStudioRoot = rootDir

        guard let pythonExec = resolvePythonExecutable() else {
            showErrorState(
                title: "未检测到可用的 Python 3 环境",
                detail: "启动 Maya · Strata Studio 本地控制面需要 Python 3.9+。",
                diagnostics: """
                已检查常见路径：/opt/homebrew/bin/python3、/usr/local/bin/python3、$HOME/.local/bin/python3、/usr/bin/python3。
                您也可以通过环境变量 MAYA_PYTHON 指定 Python 3 可执行文件路径后重新打开应用。
                """
            )
            return
        }

        showLoadingState(
            title: "正在启动本地控制面与代理网关…",
            detail: "使用 \(pythonExec) 启动 python3 -m studio (port \(studioPort) / proxy \(proxyPort))"
        )

        outputBuffer = ""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExec)
        proc.arguments = [
            "-m", "studio",
            "--host", studioHost,
            "--port", String(studioPort),
            "--proxy-port", String(proxyPort),
            "--auto-attach",
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: rootDir)

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/Library/Frameworks/Python.framework/Versions/Current/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existingPath = env["PATH"] ?? ""
        let mergedPath = (extraPaths + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, item in
                if !item.isEmpty && !acc.contains(item) { acc.append(item) }
            }
            .joined(separator: ":")
        env["PATH"] = mergedPath
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["MAYA_STUDIO_ROOT"] = rootDir
        if let existingPyPath = env["PYTHONPATH"], !existingPyPath.isEmpty {
            env["PYTHONPATH"] = "\(rootDir):\(existingPyPath)"
        } else {
            env["PYTHONPATH"] = rootDir
        }
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendOutput(chunk)
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                if self.spawnedBackendProcess === terminated {
                    self.spawnedBackendProcess = nil
                }
                if self.startupAttemptId == attempt && !self.overlayView.isHidden {
                    let logs = self.outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.showErrorState(
                        title: "本地控制面服务意外退出 (Exit \(terminated.terminationStatus))",
                        detail: "Python 进程在就绪前退出，请检查 Python 环境或端口占用情况。",
                        diagnostics: logs.isEmpty
                            ? "Python: \(pythonExec)\n目录: \(rootDir)\n无额外错误输出。"
                            : "Python: \(pythonExec)\n目录: \(rootDir)\n\n\(logs)"
                    )
                }
            }
        }

        do {
            try proc.run()
            self.spawnedBackendProcess = proc
            waitForHTTPAndLoad(attempt: attempt, timeoutSeconds: 25.0)
        } catch {
            showErrorState(
                title: "无法拉起 Python 控制面进程",
                detail: error.localizedDescription,
                diagnostics: "Python: \(pythonExec)\n工作目录: \(rootDir)"
            )
        }
    }

    private func waitForHTTPAndLoad(attempt: Int, timeoutSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let probeURL = URL(string: "http://\(studioHost):\(studioPort)/api/studio/state")!

        Task { @MainActor [weak self] in
            while Date() < deadline {
                guard let self, self.startupAttemptId == attempt else { return }

                if await Self.isHTTPResponsive(url: probeURL) {
                    guard self.startupAttemptId == attempt else { return }
                    self.loadStudioPage()
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            guard let self, self.startupAttemptId == attempt else { return }
            let logs = self.outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            self.showErrorState(
                title: "等待控制面服务就绪超时",
                detail: "在 \(Int(timeoutSeconds)) 秒内未收到 http://\(self.studioHost):\(self.studioPort) 的 HTTP 响应。",
                diagnostics: logs.isEmpty
                    ? "请确认端口 \(self.studioPort) 未被异常阻塞，或尝试在终端运行 python3 -m studio 排查。"
                    : logs
            )
        }
    }

    private func loadStudioPage() {
        var req = URLRequest(url: studioURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        webView.load(req)
    }

    func terminateOwnedBackendIfNeeded() {
        if let act = backgroundActivity {
            ProcessInfo.processInfo.endActivity(act)
            backgroundActivity = nil
        }
        // Strictly terminate ONLY the backend process spawned by this .app instance.
        // Never touch external studio servers, keepalive_colab.sh, or remote Colab VMs.
        guard let proc = spawnedBackendProcess else { return }
        spawnedBackendProcess = nil
        guard proc.isRunning else { return }

        let pid = proc.processIdentifier
        proc.terminate() // Sends SIGTERM

        let deadline = Date().addingTimeInterval(1.5)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning && pid > 0 {
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Overlay States & Actions

    private func showLoadingState(title: String, detail: String) {
        overlayView.isHidden = false
        overlayView.alphaValue = 1.0
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusTitleLabel.stringValue = title
        statusDetailLabel.stringValue = detail
        errorScrollView.isHidden = true
        retryButton.isHidden = true
        openRootButton.isHidden = true
        quitButton.isHidden = true
    }

    private func showErrorState(title: String, detail: String, diagnostics: String) {
        overlayView.isHidden = false
        overlayView.alphaValue = 1.0
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusTitleLabel.stringValue = title
        statusDetailLabel.stringValue = detail
        errorTextView.string = diagnostics
        errorScrollView.isHidden = false
        retryButton.isHidden = false
        openRootButton.isHidden = (resolvedStudioRoot == nil)
        quitButton.isHidden = false
    }

    private func hideLoadingOverlay() {
        guard !overlayView.isHidden else { return }
        spinner.stopAnimation(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            overlayView.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                self.overlayView.isHidden = true
                self.overlayView.alphaValue = 1.0
            }
        })
    }

    private func appendOutput(_ chunk: String) {
        outputBuffer += chunk
        if outputBuffer.count > 8192 {
            outputBuffer = String(outputBuffer.suffix(8192))
        }
    }

    @objc private func retryStartup(_ sender: Any?) {
        terminateOwnedBackendIfNeeded()
        start()
    }

    @objc private func revealStudioRoot(_ sender: Any?) {
        if let root = resolvedStudioRoot {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - Menu Responder Actions

    @objc func reloadConsole(_ sender: Any?) {
        if webView.url == nil {
            start()
        } else {
            loadStudioPage()
        }
    }

    @objc func openCurrentInBrowser(_ sender: Any?) {
        NSWorkspace.shared.open(webView.url ?? studioURL)
    }

    @objc func resetPageZoom(_ sender: Any?) {
        webView.pageZoom = 1.0
    }

    @objc func zoomInPage(_ sender: Any?) {
        webView.pageZoom = min(webView.pageZoom + 0.1, 2.0)
    }

    @objc func zoomOutPage(_ sender: Any?) {
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.7)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideLoadingOverlay()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleWebNavigationError(error)
    }

    private func handleWebNavigationError(_ error: Error) {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return
        }
        showErrorState(
            title: "页面加载失败",
            detail: "无法加载 \(studioURL.absoluteString)",
            diagnostics: "\(error.localizedDescription)\n\n请确认控制面服务正在运行，然后点击「重试连接」。"
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Open target="_blank" / new-window links in the default system browser
        if navigationAction.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame {
            // Allow subframes (e.g. <iframe src="http://127.0.0.1:18766/">) and proxied assets
            decisionHandler(.allow)
            return
        }

        if isLocalStudioURL(url) || ["about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow)
            return
        }

        // Route external links clicked in the main frame out to default browser
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResp = navigationResponse.response as? HTTPURLResponse,
           let disp = httpResp.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disp.contains("attachment") {
            decisionHandler(.download)
            return
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKScriptMessageHandler (Native Background Audio Alerts)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "studioSound" else { return }
        if let dict = message.body as? [String: Any], let kind = dict["kind"] as? String {
            soundPlayer.play(kind: kind)
        } else if let kind = message.body as? String {
            soundPlayer.play(kind: kind)
        }
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename.isEmpty ? "download" : suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window!) { [weak self] result in
            if result == .OK, let dest = panel.url {
                self?.activeDownloads[ObjectIdentifier(download)] = dest
                completionHandler(dest)
            } else {
                completionHandler(nil)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let dest = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.beginSheetModal(for: window!) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Maya · Strata Studio"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.beginSheetModal(for: window!) { _ in
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "请确认操作"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { resp in
            completionHandler(resp == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window!) { resp in
            completionHandler(resp == .alertFirstButtonReturn ? input.stringValue : nil)
        }
    }

    // MARK: - Portable Discovery & Networking Helpers

    private func isLocalStudioURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost" || host == studioHost.lowercased() else {
            return false
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return port == studioPort || port == proxyPort
    }

    private func resolvePortableStudioRoot() -> String? {
        let fm = FileManager.default
        func hasStudioModule(_ dir: URL) -> Bool {
            let entry = dir.appendingPathComponent("studio/__main__.py").path
            return fm.fileExists(atPath: entry)
        }

        // 1. Explicit environment override
        if let envRoot = ProcessInfo.processInfo.environment["MAYA_STUDIO_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envRoot.isEmpty {
            let url = URL(fileURLWithPath: envRoot)
            if hasStudioModule(url) { return url.path }
        }

        // 2. Walk up from MayaStudio.app location (supports repo root or build/MayaStudio.app)
        var cursor = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            if hasStudioModule(cursor) {
                return cursor.path
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        // 3. Embedded bundle Resources/studio/ (when .app is moved to /Applications)
        if let resURL = Bundle.main.resourceURL, hasStudioModule(resURL) {
            return resURL.path
        }

        // 4. Standard installed skill location under $HOME
        let skillDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/config/skills/colab-maya-ds4-256g")
        if hasStudioModule(skillDir) {
            return skillDir.path
        }

        return nil
    }

    private func resolvePythonExecutable() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        if let envPy = ProcessInfo.processInfo.environment["MAYA_PYTHON"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envPy.isEmpty, fm.isExecutableFile(atPath: envPy) {
            return envPy
        }

        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "\(home)/.local/bin/python3",
            "\(home)/miniconda3/bin/python3",
            "\(home)/anaconda3/bin/python3",
            "/usr/bin/python3",
        ]

        for path in candidates where fm.isExecutableFile(atPath: path) {
            if isUsablePython3(path) {
                return path
            }
        }
        return nil
    }

    private func isUsablePython3(_ path: String) -> Bool {
        // Avoid triggering macOS Xcode CLT stub dialog on /usr/bin/python3 if CLT is missing
        if path == "/usr/bin/python3" {
            let clt = Process()
            clt.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            clt.arguments = ["-p"]
            clt.standardOutput = Pipe()
            clt.standardError = Pipe()
            if (try? clt.run()) != nil {
                clt.waitUntilExit()
                if clt.terminationStatus != 0 {
                    return false
                }
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func isTCPPortListening(host: String, port: Int) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &res)
        guard status == 0, let first = res else { return false }
        defer { freeaddrinfo(res) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let current = ptr {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                let rc = Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
                if rc == 0 {
                    Darwin.close(fd)
                    return true
                }
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let polled = Darwin.poll(&pfd, 1, 300)
                    if polled > 0 {
                        var sockErr: Int32 = 0
                        var errLen = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) == 0 && sockErr == 0 {
                            Darwin.close(fd)
                            return true
                        }
                    }
                }
                Darwin.close(fd)
            }
            ptr = current.pointee.ai_next
        }
        return false
    }

    nonisolated private static func isHTTPResponsive(url: URL) async -> Bool {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.0)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                return http.statusCode >= 200 && http.statusCode < 500
            }
            return false
        } catch {
            return false
        }
    }
}
