import Foundation
import CFNetwork
import Darwin

enum CodexIssue: String, Equatable {
    case missingCLI, startup, authentication, unsupportedAccount, network, rateLimited
    case service, accessDenied, timeout, invalidResponse, incompatible, cancelled, unknown

    var title: String {
        switch self {
        case .missingCLI: return "未找到 Codex"
        case .startup: return "Codex 启动失败"
        case .authentication: return "需要重新登录"
        case .unsupportedAccount: return "暂无订阅限额"
        case .network: return "网络连接失败"
        case .rateLimited: return "查询暂时被限流"
        case .service: return "服务暂时不可用"
        case .accessDenied: return "访问被拒绝"
        case .timeout: return "查询超时"
        case .invalidResponse: return "响应格式异常"
        case .incompatible: return "需要更新 Codex"
        case .cancelled: return "操作已取消"
        case .unknown: return "查询暂时失败"
        }
    }

    var recovery: String {
        switch self {
        case .missingCLI: return "安装 Codex CLI，或选择已有 codex 可执行文件，然后立即刷新。"
        case .startup: return "在终端运行 codex --version 检查 CLI 和配置；必要时更新 CLI 或重新选择文件。"
        case .authentication: return "点击“登录 Codex”，在浏览器中完成 ChatGPT 登录；也可在终端运行 codex login。"
        case .unsupportedAccount: return "需要提供订阅限额的 ChatGPT 账户。API Key、第三方 API 或某些账户没有 5h / 周限额。"
        case .network, .timeout: return "检查网络；使用代理时打开系统代理并启用下方选项，然后立即刷新。程序也会自动重试。"
        case .rateLimited: return "稍后自动重试；可把查询间隔调长。查询限流不等于订阅额度已用完。"
        case .service: return "服务端暂时出错，会自动重试；持续失败时查看 OpenAI 服务状态。"
        case .accessDenied: return "检查账户访问权限、网络和代理后重试；仍失败可重新登录或查看服务状态。"
        case .invalidResponse, .incompatible: return "更新 Codex CLI 后重试，并确认选择的是官方 codex 可执行文件。"
        case .cancelled: return "可重新点击登录或立即刷新。"
        case .unknown: return "先立即刷新；检查网络和 Codex 登录。持续失败时更新 Codex CLI。"
        }
    }

    var isTransient: Bool {
        [.network, .rateLimited, .service, .timeout, .unknown].contains(self)
    }

    var canKeepPreviousData: Bool {
        ![.authentication, .unsupportedAccount, .cancelled].contains(self)
    }

    static func classify(_ message: String, code: Int? = nil) -> CodexIssue {
        let text = message.lowercased()
        if code == -32601 || text.contains("method not found") { return .incompatible }
        if text.contains("api key") || text.contains("apikey") || text.contains("not supported for") { return .unsupportedAccount }
        if text.contains("401") || text.contains("unauthorized") || text.contains("not logged") || text.contains("refresh token") || text.contains("authentication") || text.contains("expired") { return .authentication }
        if text.contains("429") || text.contains("too many requests") { return .rateLimited }
        if text.contains("403") || text.contains("forbidden") { return .accessDenied }
        if text.range(of: #"\b5[0-9]{2}\b"#, options: .regularExpression) != nil { return .service }
        if text.contains("timeout") || text.contains("timed out") { return .timeout }
        if ["connect", "network", "dns", "resolve", "tls", "certificate", "sending request"].contains(where: text.contains) { return .network }
        return .unknown
    }
}

struct QuotaWindow: Equatable {
    let remaining: Double
    let resetsAt: Date?
}

struct QuotaSnapshot: Equatable {
    let fiveHour: QuotaWindow?
    let weekly: QuotaWindow?
    let issue: CodexIssue?
    let detail: String?
    var error: String? { issue?.title }

    init(fiveHour: QuotaWindow? = nil, weekly: QuotaWindow? = nil,
         issue: CodexIssue? = nil, detail: String? = nil) {
        self.fiveHour = fiveHour; self.weekly = weekly
        self.issue = issue; self.detail = detail
    }

    func preservingLastKnown(_ previous: QuotaSnapshot) -> QuotaSnapshot {
        guard let issue, issue.canKeepPreviousData else { return self }
        return .init(fiveHour: previous.fiveHour, weekly: previous.weekly, issue: issue, detail: detail)
    }
}

struct CodexOptions: Sendable {
    var customPath = ""
    var useSystemProxy = true

    var executableURL: URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let custom = (customPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let candidates = custom.isEmpty ? [
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.cargo/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" } : [custom]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Preserve explicit terminal proxy configuration; GUI launches can instead use the system HTTP proxy.
        guard useSystemProxy,
              !["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"].contains(where: { env[$0]?.isEmpty == false }),
              let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return env }
        for (enabled, hostKey, portKey) in [
            (kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort),
            (kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy, kCFNetworkProxiesHTTPPort)
        ] {
            guard (settings[enabled as String] as? NSNumber)?.boolValue == true,
                  let host = settings[hostKey as String] as? String,
                  let port = settings[portKey as String] as? Int, (1...65535).contains(port) else { continue }
            var components = URLComponents()
            components.scheme = "http"; components.host = host; components.port = port
            guard let proxy = components.url?.absoluteString else { continue }
            env["HTTPS_PROXY"] = proxy; env["HTTP_PROXY"] = proxy
            break
        }
        return env
    }
}

final class QuotaSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?
    private var stopped = false

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if let currentProcess, currentProcess.isRunning { currentProcess.terminate() }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func sample(executableURL: URL? = nil, timeout: TimeInterval = 20, options: CodexOptions = .init(),
                onLoginURL: (@Sendable (URL) -> Void)? = nil) -> QuotaSnapshot {
        guard let executable = executableURL ?? options.executableURL else { return .init(issue: .missingCLI) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = options.environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        lock.lock()
        guard !stopped else { lock.unlock(); return .init(issue: .cancelled) }
        currentProcess = process
        do { try process.run() } catch {
            currentProcess = nil; lock.unlock()
            return .init(issue: .startup)
        }
        lock.unlock()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            output.fileHandleForReading.closeFile()
            lock.lock(); currentProcess = nil; lock.unlock()
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        func send(_ method: String, id: Int? = nil, params: [String: Any]? = nil) throws {
            var message: [String: Any] = ["method": method]
            if let id { message["id"] = id }
            if let params { message["params"] = params }
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        var deadline = ProcessInfo.processInfo.systemUptime + timeout
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        var refreshedToken = false
        var loginID: String?
        do {
            try send("initialize", id: 1, params: ["clientInfo": ["name": "glassmetrics", "title": "Glass Metrics", "version": "0.4.0"]])
            while ProcessInfo.processInfo.systemUptime < deadline && !isStopped {
                let ready = poll(&descriptor, 1, 250)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                let count = read(descriptor.fd, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return .init(issue: isStopped ? .cancelled : .startup) }
                buffer.append(contentsOf: chunk.prefix(count))
                guard buffer.count <= 1_048_576 else { return .init(issue: .invalidResponse) }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    let id = object["id"] as? Int
                    if let error = object["error"] as? [String: Any], id != nil {
                        let failure = Self.serverFailure(error)
                        if id == 3 && failure.issue == .authentication && !refreshedToken {
                            refreshedToken = true
                            try send("account/read", id: 4, params: ["refreshToken": true])
                            continue
                        }
                        return failure
                    }
                    let result = object["result"] as? [String: Any]
                    switch id {
                    case 1:
                        guard result != nil else { return .init(issue: .invalidResponse) }
                        try send("initialized")
                        if onLoginURL != nil { try send("account/login/start", id: 10, params: ["type": "chatgpt"]) }
                        else { try send("account/read", id: 2, params: ["refreshToken": false]) }
                    case 2, 4:
                        guard let result else { return .init(issue: .invalidResponse) }
                        guard let account = result["account"] as? [String: Any] else { return .init(issue: .authentication) }
                        guard let type = account["type"] as? String, ["chatgpt", "chatgptAuthTokens"].contains(type) else {
                            return .init(issue: .unsupportedAccount)
                        }
                        try send("account/rateLimits/read", id: id == 4 ? 5 : 3)
                    case 3, 5:
                        guard let result else { return .init(issue: .invalidResponse) }
                        return Self.parse(result)
                    case 10:
                        guard let result, let value = result["authUrl"] as? String, let url = URL(string: value),
                              Self.isTrustedLoginURL(url), let identifier = result["loginId"] as? String else {
                            return .init(issue: .invalidResponse)
                        }
                        loginID = identifier
                        deadline = ProcessInfo.processInfo.systemUptime + 180
                        onLoginURL?(url)
                    default: break
                    }
                    if object["method"] as? String == "account/login/completed",
                       let params = object["params"] as? [String: Any], let loginID,
                       params["loginId"] as? String == loginID {
                        guard params["success"] as? Bool == true else {
                            return Self.serverFailure(["message": params["error"] as? String ?? "Authentication failed"])
                        }
                        deadline = ProcessInfo.processInfo.systemUptime + timeout
                        try send("account/read", id: 2, params: ["refreshToken": false])
                    }
                }
            }
        } catch { return .init(issue: isStopped ? .cancelled : .startup) }
        return .init(issue: isStopped ? .cancelled : .timeout)
    }

    static func isTrustedLoginURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }

    static func serverFailure(_ error: [String: Any]) -> QuotaSnapshot {
        let message = error["message"] as? String ?? ""
        let code = error["code"] as? Int
        let issue = CodexIssue.classify(message, code: code)
        var codes: [String] = []
        if let code { codes.append("RPC \(code)") }
        if let range = message.range(of: #"\b[45][0-9]{2}\b"#, options: .regularExpression) {
            codes.append("HTTP \(message[range])")
        }
        // Never display/log arbitrary server messages: they may contain URLs, account data or tokens.
        return .init(issue: issue, detail: codes.isEmpty ? nil : codes.joined(separator: " · "))
    }

    static func parse(_ result: [String: Any]) -> QuotaSnapshot {
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let selected = buckets?["codex"] ?? result["rateLimits"] as? [String: Any] else {
            return .init(issue: .unsupportedAccount)
        }
        let windows = [selected["primary"], selected["secondary"]].compactMap { parseWindow($0) }
        let five = windows.first { $0.minutes == 300 }?.window
        let week = windows.first { $0.minutes == 10080 }?.window
        return .init(fiveHour: five, weekly: week, issue: five == nil && week == nil ? .unsupportedAccount : nil)
    }

    private static func parseWindow(_ raw: Any?) -> (minutes: Int, window: QuotaWindow)? {
        guard let data = raw as? [String: Any], let used = data["usedPercent"] as? Double, used.isFinite,
              let minutes = data["windowDurationMins"] as? Int, minutes > 0 else { return nil }
        let stamp = data["resetsAt"] as? Double
        return (minutes, .init(remaining: max(0, min(100, 100 - used)),
                               resetsAt: stamp.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }))
    }
}
