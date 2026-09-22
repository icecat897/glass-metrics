import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor final class MonitorState: ObservableObject {
    @Published var temperature: Double?
    @Published var download: Double?
    @Published var upload: Double?
    @Published var quota = QuotaSnapshot()
    @Published private(set) var quotaRunning = false
    @Published private(set) var lastQuotaUpdate: Date?
    @Published private(set) var nextQuotaAttempt: Date?
    @Published private(set) var loginInProgress = false
    @Published private(set) var loginStatus: String?
    @Published var codexPath = UserDefaults.standard.string(forKey: "codexPath") ?? "" {
        didSet {
            UserDefaults.standard.set(codexPath, forKey: "codexPath")
            quota = .init(); lastQuotaUpdate = nil
        }
    }
    @Published var useSystemProxy = UserDefaults.standard.object(forKey: "useSystemProxy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useSystemProxy, forKey: "useSystemProxy") }
    }
    @Published var networkInterval: Int = UserDefaults.standard.object(forKey: "networkInterval") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(networkInterval, forKey: "networkInterval"); startNetwork() }
    }
    @Published var temperatureInterval: Int = UserDefaults.standard.object(forKey: "temperatureInterval") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(temperatureInterval, forKey: "temperatureInterval"); startTemperature() }
    }
    @Published var codexInterval: Int = UserDefaults.standard.object(forKey: "codexInterval") as? Int ?? 120 {
        didSet { UserDefaults.standard.set(codexInterval, forKey: "codexInterval"); startQuota() }
    }
    @Published var floating: Bool = UserDefaults.standard.object(forKey: "floating") as? Bool ?? false {
        didSet { UserDefaults.standard.set(floating, forKey: "floating"); onWindowModeChange?() }
    }
    @Published var glassOpacity: Double = UserDefaults.standard.object(forKey: "glassOpacity") as? Double ?? 0.55 {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: "glassOpacity") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onWindowModeChange: (() -> Void)?
    private var networkTimer: Timer?
    private var temperatureTimer: Timer?
    private var quotaTimer: Timer?
    private let network = NetworkSampler()
    private let temperatureReader = TemperatureSampler()
    private let quotaReader = QuotaSampler()
    private var loginReader: QuotaSampler?
    private var temperatureRunning = false
    private var consecutiveFailures = 0

    var codexOptions: CodexOptions { .init(customPath: codexPath, useSystemProxy: useSystemProxy) }

    func start() {
        startNetwork()
        startTemperature()
        startQuota()
        readTemperature()
        readQuota()
    }

    func stop() {
        networkTimer?.invalidate()
        temperatureTimer?.invalidate()
        quotaTimer?.invalidate()
        quotaReader.stop()
        loginReader?.stop()
    }

    private func startTemperature() {
        temperatureTimer?.invalidate()
        temperatureTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(temperatureInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readTemperature() }
        }
        temperatureTimer?.tolerance = TimeInterval(temperatureInterval) * 0.1
    }

    private func startQuota() {
        scheduleQuota(after: TimeInterval(codexInterval))
    }

    private func scheduleQuota(after delay: TimeInterval) {
        quotaTimer?.invalidate()
        nextQuotaAttempt = Date().addingTimeInterval(delay)
        quotaTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.readQuota() }
        }
        quotaTimer?.tolerance = min(10, delay * 0.1)
    }

    private func startNetwork() {
        networkTimer?.invalidate()
        _ = network.sample()
        networkTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(networkInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sample = self.network.sample() else { return }
                self.download = sample.download
                self.upload = sample.upload
            }
        }
        networkTimer?.tolerance = 0.1
    }

    private func readTemperature() {
        // Serialize access to the cached native sensor service.
        guard !temperatureRunning else { return }
        temperatureRunning = true
        let reader = temperatureReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = reader.sample()?.rounded()
            DispatchQueue.main.async {
                if self?.temperature != value { self?.temperature = value }
                self?.temperatureRunning = false
            }
        }
    }

    private func readQuota() {
        guard !quotaRunning, !loginInProgress else { return }
        quotaTimer?.invalidate()
        nextQuotaAttempt = nil
        quotaRunning = true
        let reader = quotaReader
        let options = codexOptions
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = reader.sample(options: options)
            DispatchQueue.main.async {
                self?.quotaRunning = false
                self?.acceptQuota(value)
            }
        }
    }

    private func acceptQuota(_ value: QuotaSnapshot) {
        quota = value.preservingLastKnown(quota)
        if let issue = value.issue {
            if !issue.canKeepPreviousData { lastQuotaUpdate = nil }
            consecutiveFailures += 1
            let delay = issue.isTransient ? min(600, 30 * pow(2, Double(min(consecutiveFailures - 1, 5))))
                                          : max(600, Double(codexInterval))
            scheduleQuota(after: delay)
        } else {
            lastQuotaUpdate = Date()
            consecutiveFailures = 0
            scheduleQuota(after: TimeInterval(codexInterval))
        }
    }

    func refreshQuota() {
        guard !quotaRunning, !loginInProgress else { return }
        consecutiveFailures = 0
        loginStatus = nil
        readQuota()
    }

    func loginCodex() {
        guard !loginInProgress, !quotaRunning else { return }
        quotaTimer?.invalidate(); nextQuotaAttempt = nil
        loginInProgress = true
        loginStatus = "正在打开官方登录页…"
        // A different account may be selected; do not carry over the previous account's quota.
        quota = .init(); lastQuotaUpdate = nil
        let reader = QuotaSampler(), options = codexOptions
        loginReader = reader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = reader.sample(options: options, onLoginURL: { [weak self] url in
                DispatchQueue.main.async {
                    guard self?.loginInProgress == true else { return }
                    if NSWorkspace.shared.open(url) { self?.loginStatus = "请在浏览器完成 ChatGPT 登录。" }
                    else { self?.loginStatus = "浏览器无法打开，可在终端运行 codex login。"; reader.stop() }
                }
            })
            DispatchQueue.main.async {
                guard let self else { return }
                self.loginReader = nil
                self.loginInProgress = false
                self.loginStatus = value.issue == nil ? "登录成功，限额已更新。" : value.issue?.title
                self.acceptQuota(value)
            }
        }
    }

    func cancelLogin() { loginReader?.stop() }

    func chooseCodex() {
        let chooser = NSOpenPanel()
        chooser.title = "选择 codex 可执行文件"
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        if chooser.runModal() == .OK, let url = chooser.url {
            codexPath = url.path
            refreshQuota()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch at login: %@", error.localizedDescription) }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct MetricCard: View {
    @ObservedObject var state: MonitorState
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SYSTEM  /  LIVE").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(2).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(state.temperature.map { String(format: "%.0f", $0) } ?? "—")
                            .font(.system(size: 49, weight: .light, design: .rounded))
                        Text("°C").font(.system(size: 19, weight: .light))
                    }
                    .monospacedDigit()
                    Text("CPU TEMPERATURE").font(.system(size: 10, weight: .medium))
                        .tracking(1.2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 9) {
                    speedRow("arrow.down", value: state.download, color: .cyan)
                    speedRow("arrow.up", value: state.upload, color: .mint)
                }
                .padding(.top, 22)
            }
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
            HStack {
                Text("CODEX").font(.system(size: 10, weight: .semibold)).tracking(1.7)
                Spacer()
                if let error = state.quota.error {
                    Text(state.lastQuotaUpdate == nil ? error : "旧数据 · \(error)")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        .help(state.quota.issue?.recovery ?? error)
                }
            }
            quotaRow("5H", state.quota.fiveHour)
                .opacity(state.quota.error == nil ? 1 : 0.5)
            quotaRow("WEEK", state.quota.weekly)
                .opacity(state.quota.error == nil ? 1 : 0.5)
        }
        .padding(.horizontal, 22).padding(.vertical, 19)
        .frame(width: 360, height: 214)
        .background {
            if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: 27).fill(.clear)
                    .glassEffect(.clear, in: .rect(cornerRadius: 27))
                    .opacity(state.glassOpacity)
            } else {
                RoundedRectangle(cornerRadius: 27).fill(.ultraThinMaterial).opacity(state.glassOpacity)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 27))
    }

    private func speedRow(_ icon: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(formatSpeed(value)).font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit().frame(width: 103, alignment: .trailing)
        }
    }

    private func quotaRow(_ title: String, _ quota: QuotaWindow?) -> some View {
        HStack(spacing: 9) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 37, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.10))
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: geometry.size.width * CGFloat((quota?.remaining ?? 0) / 100))
                }
            }.frame(height: 5)
            Text(quota.map { String(format: "%.0f%%", $0.remaining) } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 35, alignment: .trailing)
            Text(resetText(quota?.resetsAt)).font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func formatSpeed(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds >= 86_400 { return "\(seconds / 86_400)d later" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h later" }
        return "\(max(1, seconds / 60))m later"
    }
}

struct SettingsView: View {
    @ObservedObject var state: MonitorState
    var body: some View {
        TabView {
            Form {
                Picker("网速刷新", selection: $state.networkInterval) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("温度刷新", selection: $state.temperatureInterval) {
                    ForEach([1, 2, 5, 10, 30, 60], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("Codex 刷新", selection: $state.codexInterval) {
                    Text("30 秒").tag(30)
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) 分钟").tag($0 * 60) }
                }
                Toggle("始终置顶", isOn: $state.floating)
                HStack {
                    Text("背景厚度")
                    Slider(value: $state.glassOpacity, in: 0.15...1)
                    Text("\(Int(state.glassOpacity * 100))%")
                        .monospacedDigit().frame(width: 38)
                }
                Toggle("登录时启动", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                Text("左键拖动卡片；右键打开设置或退出。关闭置顶后，卡片留在桌面层。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("外观与刷新", systemImage: "slider.horizontal.3") }

            Form {
                Section("账户与限额") {
                    Text(state.loginStatus ?? (state.quotaRunning ? "正在查询…" : state.quota.error ?? (state.lastQuotaUpdate == nil ? "尚未查询" : "连接正常")))
                        .font(.headline)
                    if let issue = state.quota.issue {
                        Text(issue.recovery).font(.caption).foregroundStyle(.secondary)
                        if let detail = state.quota.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let date = state.lastQuotaUpdate {
                        LabeledContent("上次成功", value: date.formatted(date: .omitted, time: .standard))
                    }
                    if let date = state.nextQuotaAttempt {
                        LabeledContent("下次尝试", value: date.formatted(date: .omitted, time: .standard))
                    }
                    HStack {
                        Button("立即刷新") { state.refreshQuota() }
                            .disabled(state.quotaRunning || state.loginInProgress)
                        Button("登录 Codex") { state.loginCodex() }
                            .disabled(state.quotaRunning || state.loginInProgress)
                        if state.loginInProgress { Button("取消登录") { state.cancelLogin() } }
                    }
                    Text("使用官方 ChatGPT 浏览器登录，复用本机 Codex CLI 账户；更换登录会影响使用同一账户配置的 Codex。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("连接") {
                    Toggle("使用系统 HTTP 代理", isOn: $state.useSystemProxy)
                    Text(state.codexOptions.executableURL?.path ?? "未找到 codex，请安装官方 CLI 或手动选择。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("选择 Codex…") { state.chooseCodex() }
                            .disabled(state.quotaRunning || state.loginInProgress)
                        if !state.codexPath.isEmpty {
                            Button("自动查找") { state.codexPath = ""; state.refreshQuota() }
                                .disabled(state.quotaRunning || state.loginInProgress)
                        }
                        Link("CLI 安装说明", destination: URL(string: "https://developers.openai.com/codex/cli/")!)
                    }
                    Text("代理选项读取系统手动 HTTP/HTTPS 代理；不支持仅 PAC。显式代理环境变量优先。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Codex", systemImage: "person.crop.circle") }
        }
        .frame(width: 470, height: 510)
    }
}

// Static card content uses native mouse handling so text and glass never swallow a drag.
final class CardHostingView: NSHostingView<MetricCard> {
    var cardMenu: NSMenu?
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { window?.performDrag(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let cardMenu { NSMenu.popUpContextMenu(cardMenu, with: event, for: self) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = MonitorState()
    private var panel: NSPanel!
    private var settings: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !UserDefaults.standard.bool(forKey: "interactionV2") {
            state.floating = false
            UserDefaults.standard.set(true, forKey: "interactionV2")
        }
        let rect = NSRect(x: 0, y: 0, width: 360, height: 214)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.delegate = self
        panel.isMovableByWindowBackground = true
        let host = CardHostingView(rootView: MetricCard(state: state))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerRadius = 27
        host.layer?.masksToBounds = true
        panel.contentView = host
        panel.setFrameAutosaveName("GlassMetricsCard")
        if !panel.setFrameUsingName("GlassMetricsCard") { panel.center() }
        state.onWindowModeChange = { [weak self] in self?.updateLevel() }
        updateLevel()
        panel.orderFrontRegardless()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "立即刷新 Codex", action: #selector(refreshCodex), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        host.cardMenu = menu
        state.start()
    }

    private func updateLevel() {
        panel.level = state.floating ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = state.floating
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSWindow === panel { panel.saveFrame(usingName: "GlassMetricsCard") }
    }
    func windowWillClose(_ notification: Notification) {
        // Release the settings view when closed so it stops observing each network update.
        if notification.object as? NSWindow === settings { settings = nil }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { state.stop() }
    @objc private func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 510),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Glass Metrics 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(state: state))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
    @objc private func refreshCodex() { state.refreshQuota() }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main struct GlassMetricsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
