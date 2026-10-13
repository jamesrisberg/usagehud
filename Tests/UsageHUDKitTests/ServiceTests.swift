import Foundation
import XCTest
@testable import UsageHUDKit

/// A thread-safe box for the fakes' state.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&value); lock.unlock() }
}

/// Records every request and answers from a per-host script (the last answer repeats).
final class FakeTransport: UsageTransport {
    let requests = Locked<[URLRequest]>([])
    let script = Locked<[String: [TransportResponse]]>([:])

    func answer(_ host: String, _ responses: TransportResponse...) { script.update { $0[host] = responses } }

    func send(_ request: URLRequest) async -> TransportResponse {
        requests.update { $0.append(request) }
        let host = request.url?.host ?? ""
        var reply = TransportResponse(status: nil, failure: "unscripted")
        script.update { s in
            guard var queue = s[host], !queue.isEmpty else { return }
            reply = queue.count > 1 ? queue.removeFirst() : queue[0]
            s[host] = queue
        }
        return reply
    }

    var hosts: [String] { requests.get().compactMap { $0.url?.host } }
}

/// Claude Code's store: a stamp (free to read) and a secret (counted), each scripted.
final class FakeClaudeSource: ClaudeTokenSource {
    /// The stamps the next looks return, in order (the last repeats).
    let stampQueue = Locked<[StampLookup]>([.missing])
    let secrets = Locked<[CredentialLookup<ClaudeToken>]>([])
    /// Every secret read: where, and whether it was the owner's refresh.
    let reads = Locked<[(CredentialStamp.Location, Bool)]>([])
    let stampReads = Locked(0)

    func keychain(changedAt dates: Date...) {
        stampQueue.set(dates.map { .present(CredentialStamp(location: .keychain, modified: $0)) })
    }
    func secret(_ lookups: CredentialLookup<ClaudeToken>...) { secrets.set(lookups) }

    var readCount: Int { reads.get().count }

    func stamp() async -> StampLookup {
        stampReads.update { $0 += 1 }
        var result: StampLookup = .missing
        stampQueue.update { queue in
            guard !queue.isEmpty else { return }
            result = queue.count > 1 ? queue.removeFirst() : queue[0]
        }
        return result
    }

    func read(_ location: CredentialStamp.Location, patient: Bool) async -> CredentialLookup<ClaudeToken> {
        reads.update { $0.append((location, patient)) }
        var result: CredentialLookup<ClaudeToken> = .missing
        secrets.update { queue in
            guard !queue.isEmpty else { return }
            result = queue.count > 1 ? queue.removeFirst() : queue[0]
        }
        return result
    }
}

final class FakeCodexSource: CodexTokenSource {
    let lookup = Locked<CredentialLookup<CodexToken>>(.missing)
    func read() -> CredentialLookup<CodexToken> { lookup.get() }
}

final class ServiceTests: XCTestCase {
    private var dir: URL!
    private var transport: FakeTransport!
    private var claude: FakeClaudeSource!
    private var codex: FakeCodexSource!
    private var clock: Locked<Date>!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-service-\(UUID().uuidString)")
        transport = FakeTransport()
        claude = FakeClaudeSource()
        codex = FakeCodexSource()
        clock = Locked(Fixtures.now)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private var cacheURL: URL { dir.appendingPathComponent(UsageCache.fileName) }

    private func service(sessionLog: CodexSessionLog? = nil) -> UsageService {
        let clock = self.clock!
        return UsageService(transport: transport, claudeSource: claude, codexSource: codex, sessionLog: sessionLog,
                            cacheURL: cacheURL, clock: { clock.get() })
    }

    private func advance(_ seconds: TimeInterval) { clock.update { $0 = $0.addingTimeInterval(seconds) } }

    private func token(_ access: String = Fixtures.claudeAccess, expiresIn: TimeInterval = 8 * 3600) -> ClaudeToken {
        ClaudeToken(accessToken: access, expiresAt: clock.get().addingTimeInterval(expiresIn), subscriptionType: "max")
    }

    private func ok(_ body: String) -> TransportResponse { TransportResponse(status: 200, body: Data(body.utf8)) }

    // MARK: Claude: when the secret is read

    func testTheSecretIsReadOnceAndHeldWhileTheItemIsUnchanged() async {
        claude.keychain(changedAt: Fixtures.now.addingTimeInterval(-3600))
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let service = service()
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(record.problem)
        XCTAssertEqual(record.reading?.plan, "max")
        XCTAssertEqual(record.reading?.windows.first?.percentUsed, 42)
        for _ in 0..<3 {
            advance(300)
            await service.refresh(.claude, trigger: .scheduled)
        }
        XCTAssertEqual(claude.readCount, 1, "the secret is read once; each poll reads only the item's stamp")
        XCTAssertEqual(claude.stampReads.get(), 4)
        XCTAssertEqual(transport.hosts.count, 4)
    }

    func testAnExpiredTokenInAnUnchangedItemCostsNothingAndBacksOff() async {
        claude.keychain(changedAt: Fixtures.now.addingTimeInterval(-9 * 3600))
        claude.secret(.found(token(expiresIn: -60)))
        let service = service()
        let first = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(first.problem, .expired)
        XCTAssertEqual(first.retryAt, clock.get().addingTimeInterval(120), "an expired token backs off like any failure")
        XCTAssertTrue(transport.requests.get().isEmpty, "an expired token is never sent, and nothing refreshes it")
        advance(60)
        await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(claude.stampReads.get(), 1, "a poll inside the backoff does not even look")
        advance(120)
        let later = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(later.problem, .expired)
        XCTAssertEqual(later.backoffLevel, 2)
        XCTAssertEqual(claude.readCount, 1, "the item has not changed, so its secret is not read again")
        XCTAssertEqual(UsageStatus.of(later, enabled: true, now: clock.get(), staleAfter: 660), .signedOut)

        // Claude Code refreshed its sign-in: the item changed, so it is read again.
        claude.keychain(changedAt: clock.get())
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        advance(300)
        let fresh = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(fresh.problem)
        XCTAssertEqual(claude.readCount, 2)
    }

    func testAPanelOpeningLooksAgainAtALocalProblemButWaitsOutARemoteOne() async {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token(expiresIn: -60)))
        let service = service()
        await service.refresh(.claude, trigger: .scheduled)
        advance(61)
        await service.refresh(.claude, trigger: .panelOpen)
        XCTAssertEqual(claude.stampReads.get(), 2, "expired: the panel checks the stamp again inside the backoff")

        claude.secret(.found(token()))
        claude.keychain(changedAt: clock.get())
        transport.answer("api.anthropic.com", TransportResponse(status: 429))
        await service.refresh(.claude, trigger: .user)
        XCTAssertEqual(transport.requests.get().count, 1)
        advance(61)
        await service.refresh(.claude, trigger: .panelOpen)
        XCTAssertEqual(transport.requests.get().count, 1, "rate-limited: the panel waits out the backoff")
    }

    func testA401RereadsOnlyWhenTheItemChanged() async {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token("OLD-claude-token")), .found(token()))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage), TransportResponse(status: 401), TransportResponse(status: 401),
                         ok(Fixtures.claudeUsage))
        let service = service()
        await service.refresh(.claude, trigger: .scheduled)
        advance(300)
        let refused = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(refused.problem, .unauthorized)
        XCTAssertEqual(claude.readCount, 1, "an unchanged item is not read again after a 401")
        XCTAssertNotNil(refused.reading)
        XCTAssertEqual(refused.problem?.hint(for: .claude), "Open Claude Code to refresh your sign-in")

        // Claude Code writes a new token while the old one is on its way: the 401 finds the item changed.
        advance(600)
        claude.keychain(changedAt: Fixtures.now, clock.get())
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(record.problem)
        XCTAssertEqual(claude.readCount, 2)
        XCTAssertEqual(transport.requests.get().map { $0.value(forHTTPHeaderField: "Authorization") ?? "" },
                       ["Bearer OLD-claude-token", "Bearer OLD-claude-token", "Bearer OLD-claude-token", "Bearer \(Fixtures.claudeAccess)"])
    }

    func testA403IsTheProvidersErrorAndNeverTouchesTheItem() async {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", TransportResponse(status: 403))
        let record = await service().refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(record.problem, .server(403))
        XCTAssertEqual(claude.stampReads.get(), 1, "no second look at the store")
        XCTAssertEqual(claude.readCount, 1)
        XCTAssertEqual(UsageStatus.of(record, enabled: true, now: clock.get(), staleAfter: 660), .error)
    }

    func testARefusedKeychainIsNotTriedAgainUntilTheItemChangesOrTheOwnerRefreshes() async {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.needsApproval)
        let first = await service().refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(first.problem, .keychainNeedsApproval)
        XCTAssertNotNil(first.retryAt, "it backs off")
        // Relaunch: the refusal is remembered.
        let relaunched = service()
        let blocked = await relaunched.claudeBlocked
        XCTAssertEqual(blocked, CredentialStamp(location: .keychain, modified: Fixtures.now))
        advance(3600)
        await relaunched.refresh(.claude, trigger: .scheduled)
        advance(3600)
        await relaunched.refresh(.claude, trigger: .panelOpen)
        XCTAssertEqual(claude.readCount, 1, "neither a poll nor a panel opening runs security again")

        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let asked = await relaunched.refresh(.claude, trigger: .user)
        XCTAssertNil(asked.problem)
        XCTAssertEqual(claude.reads.get().last?.1, true, "the owner's refresh reads, patiently")
        let cleared = await relaunched.claudeBlocked
        XCTAssertNil(cleared)

        // Refused again; then the item changes and a poll reads it.
        claude.secret(.needsApproval)
        claude.keychain(changedAt: clock.get())
        advance(300)
        await relaunched.refresh(.claude, trigger: .scheduled)
        claude.secret(.found(token()))
        claude.keychain(changedAt: clock.get().addingTimeInterval(1))
        advance(3600)
        let recovered = await relaunched.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(recovered.problem)
        XCTAssertEqual(claude.readCount, 4)
    }

    func testThePlaintextFileIsReadInTheBackgroundAndNeverMarksTheKeychain() async {
        claude.stampQueue.set([.present(CredentialStamp(location: .file, modified: Fixtures.now))])
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let service = service()
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(record.problem)
        XCTAssertEqual(claude.reads.get().first?.0, .file)
        let blocked = await service.claudeBlocked
        XCTAssertNil(blocked)
    }

    func testNoStoredSignInIsSignedOut() async {
        let record = await service().refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(record.problem, .signedOut)
        XCTAssertEqual(claude.readCount, 0)
        XCTAssertTrue(transport.requests.get().isEmpty)
    }

    // MARK: Claude: pacing

    func testA429BacksOffAndOnlyTheOwnerCanBypassIt() async {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", TransportResponse(status: 429, headers: ["retry-after": "600"]), ok(Fixtures.claudeUsage))
        let service = service()
        let limited = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(limited.problem, .rateLimited)
        XCTAssertEqual(limited.retryAt, Fixtures.now.addingTimeInterval(600), "Retry-After wins")
        advance(300)
        await service.refresh(.claude, trigger: .scheduled)
        await service.refresh(.claude, trigger: .panelOpen)
        XCTAssertEqual(transport.requests.get().count, 1, "quiet while backing off")
        let forced = await service.refresh(.claude, trigger: .user)
        XCTAssertNil(forced.problem)
        XCTAssertEqual(forced.backoffLevel, 0)
        XCTAssertEqual(transport.requests.get().count, 2)
    }

    func testRepeatedFailuresDoubleTheBackoff() async {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", TransportResponse(status: 500))
        let service = service()
        var waits: [TimeInterval] = []
        for _ in 0..<4 {
            let record = await service.refresh(.claude, trigger: .user)
            waits.append(record.retryAt!.timeIntervalSince(clock.get()))
            advance(1)
        }
        XCTAssertEqual(waits, [120, 240, 480, 960])
    }

    func testAPanelOpeningSkipsAFreshAttempt() async {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let service = service()
        await service.refresh(.claude, trigger: .panelOpen)
        advance(45)
        await service.refresh(.claude, trigger: .panelOpen)
        XCTAssertEqual(transport.requests.get().count, 1, "under a minute old")
        advance(30)
        await service.refresh(.claude, trigger: .panelOpen)
        XCTAssertEqual(transport.requests.get().count, 2)
    }

    // MARK: Codex

    func testCodexReadsLive() async {
        codex.lookup.set(.found(CodexToken(accessToken: Fixtures.jwt(expiresAt: Fixtures.now.addingTimeInterval(3600)), accountID: "acct", expiresAt: Fixtures.now.addingTimeInterval(3600))))
        transport.answer("chatgpt.com", ok(Fixtures.codexUsage))
        let record = await service().refresh(.codex, trigger: .scheduled)
        XCTAssertNil(record.problem)
        XCTAssertEqual(record.reading?.credits?.balance, 62_500)
        XCTAssertEqual(transport.requests.get().first?.value(forHTTPHeaderField: "Chatgpt-Account-Id"), "acct")
    }

    func testACodex403IsAnErrorNotASignOut() async {
        codex.lookup.set(.found(CodexToken(accessToken: "x", accountID: nil, expiresAt: nil)))
        transport.answer("chatgpt.com", TransportResponse(status: 403))
        let record = await service().refresh(.codex, trigger: .scheduled)
        XCTAssertEqual(record.problem, .server(403))
        XCTAssertEqual(record.problem?.hint(for: .codex), "Codex answered 403")
        XCTAssertNotNil(record.retryAt)
    }

    func testCodexFallsBackToTheSessionLogWhenSignedOutExpiredOrOffline() async throws {
        let logDir = dir.appendingPathComponent("sessions/2026/10/13")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try Data(Fixtures.sessionLog.utf8).write(to: logDir.appendingPathComponent("rollout-x.jsonl"))
        let log = CodexSessionLog(sessionsDirectory: dir.appendingPathComponent("sessions"))

        let signedOut = await service(sessionLog: log).refresh(.codex, trigger: .scheduled)
        XCTAssertEqual(signedOut.problem, .signedOut)
        XCTAssertNil(signedOut.retryAt, "a local Codex problem sends nothing and does not back off")
        XCTAssertEqual(signedOut.reading?.source, .sessionLog)
        XCTAssertEqual(signedOut.reading?.windows.last?.percentUsed, 4.5)
        XCTAssertEqual(signedOut.problem?.hint(for: .codex), "Run codex to sign in")

        codex.lookup.set(.found(CodexToken(accessToken: "x", accountID: nil, expiresAt: Fixtures.now.addingTimeInterval(-10))))
        advance(120)
        let expired = await service(sessionLog: log).refresh(.codex, trigger: .user)
        XCTAssertEqual(expired.problem, .expired)
        XCTAssertTrue(transport.requests.get().isEmpty, "an expired token is never sent")
        XCTAssertEqual(expired.reading?.source, .sessionLog)
        guard case .stale(let age) = UsageStatus.of(expired, enabled: true, now: clock.get(), staleAfter: 660) else {
            return XCTFail("a session-log reading is stale")
        }
        XCTAssertEqual(age, clock.get().timeIntervalSince(PayloadValues.iso8601("2026-10-13T15:58:42.070Z")!), accuracy: 0.01)
    }

    func testANewerLiveReadingIsNotReplacedByAnOlderLogRecord() async throws {
        let logDir = dir.appendingPathComponent("sessions/2026/10/13")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try Data(Fixtures.sessionLog.utf8).write(to: logDir.appendingPathComponent("rollout-x.jsonl"))
        codex.lookup.set(.found(CodexToken(accessToken: "x", accountID: nil, expiresAt: nil)))
        transport.answer("chatgpt.com", ok(Fixtures.codexUsage), TransportResponse(status: nil, failure: "offline"))
        let service = service(sessionLog: CodexSessionLog(sessionsDirectory: dir.appendingPathComponent("sessions")))
        await service.refresh(.codex, trigger: .scheduled)
        advance(300)
        let record = await service.refresh(.codex, trigger: .scheduled)
        XCTAssertEqual(record.problem, .network("offline"))
        XCTAssertEqual(record.reading?.source, .live, "the live reading at 16:00 is newer than the log's 15:58")
    }

    // MARK: The read-only rule and the cache

    /// Every scenario above, together: UsageHUD sends the two usage GETs and nothing else. No
    /// token endpoint, no body, no refresh token anywhere in a request or on disk.
    func testNeverRefreshesNeverWritesATokenOnlyEverGETsTheUsageEndpoints() async throws {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token("OLD-claude-token", expiresIn: 400)), .found(token()))
        let codexJWT = Fixtures.jwt(expiresAt: Fixtures.now.addingTimeInterval(3600))
        codex.lookup.set(.found(try XCTUnwrap(CodexToken.parse(Fixtures.codexAuth(access: codexJWT)))))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage), TransportResponse(status: 401), TransportResponse(status: 429),
                         ok(Fixtures.claudeUsage))
        transport.answer("chatgpt.com", TransportResponse(status: 401), ok(Fixtures.codexUsage))
        let service = service()
        for step in 0..<6 {
            if step == 2 { claude.keychain(changedAt: clock.get()) }
            await service.refresh(.claude, trigger: step.isMultiple(of: 2) ? .scheduled : .user)
            await service.refresh(.codex, trigger: .user)
            advance(400)
        }
        let requests = transport.requests.get()
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertTrue([ClaudeUsage.url, CodexUsage.url].contains(request.url!), "\(request.url!)")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            for value in (request.allHTTPHeaderFields ?? [:]).values {
                XCTAssertFalse(value.contains(Fixtures.claudeRefresh))
                XCTAssertFalse(value.contains(Fixtures.codexRefresh))
            }
            if request.url == CodexUsage.url {
                XCTAssertFalse((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("claude"), "each token goes only to its own provider")
            } else {
                XCTAssertNil(request.value(forHTTPHeaderField: "Chatgpt-Account-Id"))
                XCTAssertFalse((request.value(forHTTPHeaderField: "Authorization") ?? "").contains(codexJWT))
            }
        }
        let cache = try String(contentsOf: cacheURL, encoding: .utf8)
        for secret in ["OLD-claude-token", Fixtures.claudeAccess, Fixtures.claudeRefresh, codexJWT, Fixtures.codexRefresh, "acct-fixture", "Bearer"] {
            XCTAssertFalse(cache.contains(secret), "the cache holds no \(secret)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    private var sourceFiles: [(name: String, text: String)] {
        get throws {
            let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources")
            let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        }
    }

    /// The source tree has no way to refresh a token or change the Keychain: no token endpoint,
    /// no refresh grant, no Keychain write, and no read of a Keychain item's data except
    /// through `security`.
    func testTheSourcesNeverReachForARefresh() throws {
        let files = try sourceFiles
        XCTAssertGreaterThan(files.count, 5)
        for (name, text) in files {
            for forbidden in ["refresh_token", "refreshToken", "grant_type", "oauth/token", "auth.openai.com", "console.anthropic.com/v1/oauth",
                              "SecItemUpdate", "SecItemAdd", "SecItemDelete", "kSecReturnData", "SecKeychainSetUserInteractionAllowed",
                              "LAContext", "kSecUseAuthenticationUI"] {
                XCTAssertFalse(text.contains(forbidden), "\(name) mentions \(forbidden)")
            }
        }
    }

    /// The only process UsageHUD starts is `/usr/bin/security find-generic-password -s
    /// <service> -a <user> -w`.
    func testTheOnlyProcessIsSecurityFindGenericPassword() throws {
        let spawn = try NSRegularExpression(pattern: #"Process\(\)|posix_spawn|NSTask|popen\(|(?<![.\w])system\(|NSWorkspace|openApplication"#)
        let launching = try sourceFiles.filter { spawn.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
        XCTAssertEqual(launching.map(\.name), ["KeychainSecretCommand.swift"])
        XCTAssertEqual(launching.first?.text.components(separatedBy: "Process()").count, 2, "one Process, once")
        let invocation = KeychainSecretCommand.Invocation.findClaudeCredentials(service: "Claude Code-credentials", account: "jrisberg")
        XCTAssertEqual(invocation.executable.path, "/usr/bin/security")
        XCTAssertEqual(invocation.arguments, ["find-generic-password", "-s", "Claude Code-credentials", "-a", "jrisberg", "-w"])
        // Only the tests' initializer can name another program.
        let command = try XCTUnwrap(try sourceFiles.first { $0.name == "KeychainSecretCommand.swift" }?.text)
        XCTAssertTrue(command.contains("        init(executable: URL, arguments: [String]) {"), "internal, not public")
    }

    func testTheCacheRestoresReadingsAndBackoffAfterARelaunch() async throws {
        claude.keychain(changedAt: Fixtures.now)
        claude.secret(.found(token()))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage), TransportResponse(status: 429))
        let first = service()
        await first.refresh(.claude, trigger: .scheduled)
        advance(60)
        await first.refresh(.claude, trigger: .user)
        let relaunched = service()
        let record = await relaunched.record(.claude)
        XCTAssertEqual(record.reading?.windows.count, 5)
        XCTAssertEqual(record.problem, .rateLimited)
        XCTAssertEqual(record.retryAt, clock.get().addingTimeInterval(120))
        advance(61)
        await relaunched.refresh(.claude, trigger: .panelOpen)
        XCTAssertEqual(transport.requests.get().count, 2, "the backoff survives the relaunch")
        XCTAssertEqual(UsageCache.load(from: dir.appendingPathComponent("missing.json")), UsageCache())
    }

    func testTheCacheIsCreatedPrivateAndReplacesAnOpenOne() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cacheURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cacheURL.path)
        try UsageCache(records: [.codex: ProviderRecord(problem: .signedOut)]).save(to: cacheURL)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(UsageCache.load(from: cacheURL).providerRecords[.codex]?.problem, .signedOut)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }
}
