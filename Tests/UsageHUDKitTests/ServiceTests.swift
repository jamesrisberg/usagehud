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

final class FakeClaudeSource: ClaudeTokenSource {
    let lookups = Locked<[CredentialLookup<ClaudeToken>]>([])
    let calls = Locked<[Bool]>([])

    func set(_ lookups: CredentialLookup<ClaudeToken>...) { self.lookups.set(lookups) }

    func read(allowPrompt: Bool) async -> CredentialLookup<ClaudeToken> {
        calls.update { $0.append(allowPrompt) }
        var result: CredentialLookup<ClaudeToken> = .missing
        lookups.update { queue in
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

    private var claudeToken: ClaudeToken {
        ClaudeToken(accessToken: Fixtures.claudeAccess, expiresAt: Fixtures.now.addingTimeInterval(8 * 3600), subscriptionType: "max")
    }

    private func ok(_ body: String) -> TransportResponse { TransportResponse(status: 200, body: Data(body.utf8)) }

    // MARK: Claude

    func testClaudeReadsLiveAndKeepsTheTokenInMemory() async {
        claude.set(.found(claudeToken))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let service = service()
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(record.problem)
        XCTAssertEqual(record.reading?.plan, "max")
        XCTAssertEqual(record.reading?.windows.first?.percentUsed, 42)
        XCTAssertEqual(claude.calls.get(), [true], "the first read ever may show the Keychain prompt")
        advance(300)
        await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(claude.calls.get().count, 1, "the token is held in memory, so the Keychain is read once")
        XCTAssertEqual(transport.hosts, ["api.anthropic.com", "api.anthropic.com"])
        let keychainAccess = await service.keychainAccess
        XCTAssertEqual(keychainAccess, .granted)
    }

    func testAnExpiredTokenIsNeverSentAndNeverRefreshed() async {
        claude.set(.found(ClaudeToken(accessToken: Fixtures.claudeAccess, expiresAt: Fixtures.now.addingTimeInterval(-60), subscriptionType: "max")))
        let record = await service().refresh(.claude, trigger: .user)
        XCTAssertEqual(record.problem, .expired)
        XCTAssertTrue(transport.requests.get().isEmpty, "nothing is sent with an expired token, and nothing refreshes it")
        XCTAssertEqual(UsageStatus.of(record, enabled: true, now: Fixtures.now, staleAfter: 660), .signedOut)
    }

    func testATokenExpiringWhileHeldIsReReadNotRefreshed() async {
        let short = ClaudeToken(accessToken: "first", expiresAt: Fixtures.now.addingTimeInterval(600), subscriptionType: "max")
        claude.set(.found(short), .found(claudeToken))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let service = service()
        await service.refresh(.claude, trigger: .scheduled)
        advance(600)
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(record.problem)
        XCTAssertEqual(claude.calls.get(), [true, false], "re-read from the store, without a prompt once granted")
        XCTAssertEqual(transport.requests.get().last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(Fixtures.claudeAccess)")
    }

    func testA401RereadsTheStoreOnceAndRetriesWithTheNewToken() async {
        claude.set(.found(ClaudeToken(accessToken: "OLD-claude-token", expiresAt: Fixtures.now.addingTimeInterval(3600), subscriptionType: "max")),
                   .found(claudeToken))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage), TransportResponse(status: 401), ok(Fixtures.claudeUsage))
        let service = service()
        await service.refresh(.claude, trigger: .scheduled)
        advance(300)
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertNil(record.problem)
        XCTAssertEqual(transport.requests.get().map { $0.value(forHTTPHeaderField: "Authorization") ?? "" },
                       ["Bearer OLD-claude-token", "Bearer OLD-claude-token", "Bearer \(Fixtures.claudeAccess)"])
    }

    func testA401WithTheSameTokenIsUnauthorizedAndKeepsTheReadingStale() async {
        claude.set(.found(claudeToken))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage), TransportResponse(status: 401))
        let service = service()
        await service.refresh(.claude, trigger: .scheduled)
        advance(300)
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(record.problem, .unauthorized)
        XCTAssertEqual(transport.requests.get().count, 2, "no retry with the same token")
        XCTAssertNotNil(record.reading)
        XCTAssertEqual(UsageStatus.of(record, enabled: true, now: clock.get(), staleAfter: 660), .stale(age: 300))
        XCTAssertEqual(record.problem?.hint(for: .claude), "Open Claude Code to refresh your sign-in")
    }

    func testA429BacksOffAndOnlyTheOwnerCanBypassIt() async {
        claude.set(.found(claudeToken))
        transport.answer("api.anthropic.com", TransportResponse(status: 429, headers: ["retry-after": "600"]), ok(Fixtures.claudeUsage))
        let service = service()
        let limited = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(limited.problem, .rateLimited)
        XCTAssertEqual(limited.retryAt, Fixtures.now.addingTimeInterval(600), "Retry-After wins")
        advance(300)
        await service.refresh(.claude, trigger: .scheduled)
        await service.refresh(.claude, trigger: .opportunistic)
        XCTAssertEqual(transport.requests.get().count, 1, "quiet while backing off")
        let forced = await service.refresh(.claude, trigger: .user)
        XCTAssertNil(forced.problem)
        XCTAssertEqual(forced.backoffLevel, 0)
        XCTAssertEqual(transport.requests.get().count, 2)
    }

    func testRepeatedFailuresDoubleTheBackoff() async {
        claude.set(.found(claudeToken))
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

    func testOpportunisticReadsSkipAFreshAttempt() async {
        claude.set(.found(claudeToken))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let service = service()
        await service.refresh(.claude, trigger: .opportunistic)
        advance(45)
        await service.refresh(.claude, trigger: .opportunistic)
        XCTAssertEqual(transport.requests.get().count, 1, "under a minute old")
        advance(30)
        await service.refresh(.claude, trigger: .opportunistic)
        XCTAssertEqual(transport.requests.get().count, 2)
    }

    func testADeniedKeychainIsNotAskedAgainUntilTheOwnerRefreshes() async {
        claude.set(.denied)
        let first = await service().refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(first.problem, .keychainDenied)
        // Relaunch: the denial is remembered.
        let relaunched = service()
        advance(600)
        let scheduled = await relaunched.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(scheduled.problem, .keychainDenied)
        XCTAssertEqual(claude.calls.get(), [true], "no prompt from a poll after a denial, even after a relaunch")
        claude.set(.found(claudeToken))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let asked = await relaunched.refresh(.claude, trigger: .user)
        XCTAssertNil(asked.problem)
        XCTAssertEqual(claude.calls.get(), [true, true], "an explicit refresh asks again")
    }

    func testAScheduledReadThatWouldPromptAsksForARefresh() async {
        claude.set(.found(ClaudeToken(accessToken: "a", expiresAt: Fixtures.now.addingTimeInterval(120), subscriptionType: nil)), .needsApproval)
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage))
        let service = service()
        await service.refresh(.claude, trigger: .scheduled)
        advance(300)
        let record = await service.refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(record.problem, .keychainNeedsApproval)
        XCTAssertEqual(claude.calls.get(), [true, false])
        XCTAssertEqual(UsageStatus.of(record, enabled: true, now: clock.get(), staleAfter: 660), .stale(age: 300))
    }

    func testNoCredentialsIsSignedOut() async {
        let record = await service().refresh(.claude, trigger: .scheduled)
        XCTAssertEqual(record.problem, .signedOut)
        XCTAssertTrue(transport.requests.get().isEmpty)
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

    func testCodexFallsBackToTheSessionLogWhenSignedOutExpiredOrOffline() async throws {
        let logDir = dir.appendingPathComponent("sessions/2026/10/13")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try Data(Fixtures.sessionLog.utf8).write(to: logDir.appendingPathComponent("rollout-x.jsonl"))
        let log = CodexSessionLog(sessionsDirectory: dir.appendingPathComponent("sessions"))

        let signedOut = await service(sessionLog: log).refresh(.codex, trigger: .scheduled)
        XCTAssertEqual(signedOut.problem, .signedOut)
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
        claude.set(.found(ClaudeToken(accessToken: "OLD-claude-token", expiresAt: Fixtures.now.addingTimeInterval(400), subscriptionType: "max")),
                   .found(claudeToken))
        let codexJWT = Fixtures.jwt(expiresAt: Fixtures.now.addingTimeInterval(3600))
        codex.lookup.set(.found(try XCTUnwrap(CodexToken.parse(Fixtures.codexAuth(access: codexJWT)))))
        transport.answer("api.anthropic.com", ok(Fixtures.claudeUsage), TransportResponse(status: 401), TransportResponse(status: 429),
                         ok(Fixtures.claudeUsage))
        transport.answer("chatgpt.com", TransportResponse(status: 401), ok(Fixtures.codexUsage))
        let service = service()
        for step in 0..<6 {
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
        }
        let cache = try String(contentsOf: cacheURL, encoding: .utf8)
        for secret in ["OLD-claude-token", Fixtures.claudeAccess, Fixtures.claudeRefresh, codexJWT, Fixtures.codexRefresh, "acct-fixture", "Bearer"] {
            XCTAssertFalse(cache.contains(secret), "the cache holds no \(secret)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// The source tree has no way to refresh a token: no token endpoint and no refresh grant.
    func testTheSourcesNeverReachForARefresh() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 5)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["refresh_token", "refreshToken", "grant_type", "oauth/token", "auth.openai.com", "console.anthropic.com/v1/oauth",
                              "SecItemUpdate", "SecItemAdd", "SecItemDelete"] {
                XCTAssertFalse(text.contains(forbidden), "\(file.lastPathComponent) mentions \(forbidden)")
            }
        }
    }

    func testTheCacheRestoresReadingsAndBackoffAfterARelaunch() async throws {
        claude.set(.found(claudeToken))
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
        await relaunched.refresh(.claude, trigger: .opportunistic)
        XCTAssertEqual(transport.requests.get().count, 2, "the backoff survives the relaunch")
        let access = await relaunched.keychainAccess
        XCTAssertEqual(access, .granted)
        XCTAssertEqual(UsageCache.load(from: dir.appendingPathComponent("missing.json")), UsageCache())
    }
}
