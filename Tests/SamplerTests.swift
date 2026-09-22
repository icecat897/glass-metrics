import Foundation
import Darwin

@main struct SamplerTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() throws {
        let five: [String: Any] = ["usedPercent": 25.0, "windowDurationMins": 300, "resetsAt": 2_000_000_000.0]
        let week: [String: Any] = ["usedPercent": 120.0, "windowDurationMins": 10080]
        let result: [String: Any] = ["rateLimitsByLimitId": ["codex": ["primary": five, "secondary": week]],
                                     "rateLimits": ["primary": ["usedPercent": 0.0, "windowDurationMins": 300]]]
        let parsed = QuotaSampler.parse(result)
        check(parsed.fiveHour?.remaining == 75, "Prefer Codex bucket and convert used to remaining")
        check(parsed.weekly?.remaining == 0, "Clamp remaining quota")
        check(parsed.fiveHour?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000), "Parse reset timestamp")
        check(QuotaSampler.parse(["rateLimits": ["primary": ["usedPercent": 10.0, "windowDurationMins": 15]]]).fiveHour == nil,
              "Do not mislabel a 15-minute quota as five-hour")
        check(QuotaSampler.parse([:]).error != nil, "Missing quota is unavailable, not zero")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func fixture(_ name: String, _ body: String) throws -> URL {
            let url = directory.appendingPathComponent(name + ".py")
            let source = "#!/usr/bin/python3\nimport json, os, sys, time, signal\n" + body
            try source.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let response = String(data: try JSONSerialization.data(withJSONObject: ["id": 3, "result": result]), encoding: .utf8)!
        let success = try fixture("success", """
        assert json.loads(sys.stdin.readline())['method'] == 'initialize'
        sys.stderr.write('x' * 200000); sys.stderr.flush()
        print(json.dumps({'id':1,'result':{}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        assert json.loads(sys.stdin.readline())['method'] == 'account/read'
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt'}}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'account/rateLimits/read'
        payload = '\(response)' + '\\n'
        print(json.dumps({'method':'notification','params':{}}), flush=True)
        for i in range(0, len(payload), 11):
            sys.stdout.write(payload[i:i+11]); sys.stdout.flush(); time.sleep(.001)
        sys.stdin.read()
        """)
        let streamed = QuotaSampler().sample(executableURL: success, timeout: 3)
        check(streamed == parsed, "Handshake, fragmented stdout and large stderr complete without deadlock")

        let silent = try fixture("silent", """
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(__file__ + '.pid', 'w').write(str(os.getpid()))
        time.sleep(30)
        """)
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = QuotaSampler().sample(executableURL: silent, timeout: 0.5)
        check(timedOut.error != nil && ProcessInfo.processInfo.systemUptime - start < 3, "Unresponsive process has bounded timeout")
        let pid = Int32(try String(contentsOfFile: silent.path + ".pid", encoding: .utf8))!
        check(kill(pid, 0) == -1 && errno == ESRCH, "Timed-out child is reaped")

        let reader = QuotaSampler()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reader.stop() }
        let cancelStart = ProcessInfo.processInfo.systemUptime
        check(reader.sample(executableURL: silent).error != nil && ProcessInfo.processInfo.systemUptime - cancelStart < 3,
              "Quit cancels an in-flight quota query")
        let stoppedReader = QuotaSampler()
        stoppedReader.stop()
        check(stoppedReader.sample(executableURL: success).error != nil, "Stopped sampler cannot start another child")

        let earlyExit = try fixture("exit", "sys.exit(0)\n")
        check(QuotaSampler().sample(executableURL: earlyExit).error != nil, "Early process exit does not crash the app")

        let transient = QuotaSnapshot(issue: .network).preservingLastKnown(parsed)
        check(transient.fiveHour == parsed.fiveHour && transient.error != nil, "Transient failure retains clearly stale quota")
        check(QuotaSnapshot(issue: .authentication).preservingLastKnown(parsed).fiveHour == nil,
              "Authentication failure clears previous account quota")
        let safeFailure = QuotaSampler.serverFailure(["code": -32603, "message": "HTTP 429 at https://example.test/private?token=secret user@example.test"])
        check(safeFailure.issue == .rateLimited && safeFailure.detail == "RPC -32603 · HTTP 429", "Error reporting keeps codes, not credentials or addresses")
        check(CodexIssue.classify("error sending request") == .network, "Classify connection failures")
        check(CodexIssue.classify("HTTP 503") == .service, "Classify server failures")
        check(CodexIssue.classify("Method not found", code: -32601) == .incompatible, "Explain incompatible CLI")
        check(QuotaSampler.isTrustedLoginURL(URL(string: "https://auth.openai.com/authorize")!), "Allow official browser login URL")
        check(!QuotaSampler.isTrustedLoginURL(URL(string: "https://auth.openai.com.evil.test/authorize")!), "Reject lookalike login hosts")
        check(!QuotaSampler.isTrustedLoginURL(URL(string: "http://auth.openai.com/authorize")!), "Reject insecure login URL")

        let handshake = """
        assert json.loads(sys.stdin.readline())['method'] == 'initialize'
        print(json.dumps({'id':1,'result':{}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'

        """
        let authPrefix = handshake + """
        assert json.loads(sys.stdin.readline())['method'] == 'account/read'
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt'}}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'account/rateLimits/read'

        """
        let refresh = try fixture("refresh", authPrefix + """
        print(json.dumps({'id':3,'error':{'code':-32603,'message':'401 Unauthorized'}}), flush=True)
        request=json.loads(sys.stdin.readline())
        assert request['method']=='account/read' and request['params']['refreshToken'] is True
        print(json.dumps({'id':4,'result':{'account':{'type':'chatgpt'}}}), flush=True)
        assert json.loads(sys.stdin.readline())['id'] == 5
        response=json.loads('\(response)');response['id']=5
        print(json.dumps(response),flush=True)
        sys.stdin.read()
        """)
        check(QuotaSampler().sample(executableURL: refresh, timeout: 3) == parsed, "Refresh expired authentication once, then retry quota")

        let absent = try fixture("not_logged_in", handshake + """
        assert json.loads(sys.stdin.readline())['method']=='account/read'
        print(json.dumps({'id':2,'result':{'account':None}}),flush=True)
        sys.stdin.read()
        """)
        check(QuotaSampler().sample(executableURL: absent, timeout: 3).issue == .authentication, "Missing account prompts login")

        let login = try fixture("login", handshake + """
        assert json.loads(sys.stdin.readline())['method']=='account/login/start'
        print(json.dumps({'id':10,'result':{'loginId':'fixture','authUrl':'https://auth.openai.com/authorize?state=fixture'}}),flush=True)
        print(json.dumps({'method':'account/login/completed','params':{'loginId':'unrelated','success':False}}),flush=True)
        print(json.dumps({'method':'account/login/completed','params':{'loginId':'fixture','success':True}}),flush=True)
        assert json.loads(sys.stdin.readline())['method']=='account/read'
        print(json.dumps({'id':2,'result':{'account':{'type':'chatgpt'}}}),flush=True)
        assert json.loads(sys.stdin.readline())['method']=='account/rateLimits/read'
        print('\(response)',flush=True)
        sys.stdin.read()
        """)
        let loginURLReceived = DispatchSemaphore(value: 0)
        let loggedIn = QuotaSampler().sample(executableURL: login, timeout: 3, onLoginURL: { _ in loginURLReceived.signal() })
        check(loggedIn == parsed && loginURLReceived.wait(timeout: .now()) == .success,
              "Browser login callback matches its login ID and refreshes quota")

        if CommandLine.arguments.contains("--live") {
            let temperature = TemperatureSampler().sample()
            check(temperature.map { (10...120).contains($0) } ?? false, "Real CPU temperature is plausible")
            let network = NetworkSampler()
            _ = network.sample()
            Thread.sleep(forTimeInterval: 1.1)
            let speed = network.sample()
            check(speed.map { $0.download >= 0 && $0.upload >= 0 } ?? false, "Real network counters produce rates")
            let quota = QuotaSampler().sample()
            check(quota.error == nil && quota.fiveHour != nil && quota.weekly != nil, "Real Codex five-hour and weekly quota available")
            print("Temperature: \(temperature!.rounded()) °C; live quota windows verified.")
        }
    }
}
