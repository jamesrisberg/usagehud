import Foundation
import XCTest
@testable import UsageHUDKit

/// `KeychainSecretCommand`, driven with stand-in programs (`/bin/sh`, `/bin/cat`, `/bin/sleep`)
/// through the tests-only initializer. The real `security` is never run here.
final class KeychainCommandTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func shell(_ script: String) -> KeychainSecretCommand.Invocation {
        .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }

    private func credentialsFile() throws -> URL {
        let url = dir.appendingPathComponent("secret.json")
        try Fixtures.claudeCredentials(expiresAt: Fixtures.now.addingTimeInterval(3600)).write(to: url)
        return url
    }

    func testTheInvocationIsExactlySecurityFindGenericPassword() {
        let invocation = KeychainSecretCommand.Invocation.findClaudeCredentials(service: "Claude Code-credentials", account: "me")
        XCTAssertEqual(invocation.executable, URL(fileURLWithPath: "/usr/bin/security"))
        XCTAssertEqual(invocation.arguments, ["find-generic-password", "-s", "Claude Code-credentials", "-a", "me", "-w"],
                       "an argument array: the service's space needs no quoting, and no secret is on the command line")
    }

    func testACleanExitIsParsed() throws {
        let invocation = KeychainSecretCommand.Invocation(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [try credentialsFile().path])
        guard case .found(let token) = KeychainSecretCommand.read(invocation, timeout: 5) else { return XCTFail("the token") }
        XCTAssertEqual(token.accessToken, Fixtures.claudeAccess)
        XCTAssertEqual(token.subscriptionType, "max")
    }

    func testExitStatusesMapToFixedMeanings() throws {
        func lookup(_ status: Int32) -> String {
            switch KeychainSecretCommand.read(shell("exit \(status)"), timeout: 5) {
            case .found: return "found"
            case .missing: return "missing"
            case .needsApproval: return "needsApproval"
            case .failed(let why): return "failed: \(why)"
            }
        }
        XCTAssertEqual(lookup(44), "missing", "errSecItemNotFound")
        XCTAssertEqual(lookup(36), "needsApproval", "errSecInteractionNotAllowed")
        XCTAssertEqual(lookup(51), "needsApproval", "errSecAuthFailed")
        XCTAssertEqual(lookup(128), "needsApproval", "errSecUserCanceled")
        XCTAssertEqual(lookup(1), "failed: The Keychain read failed (security exited 1)")
        guard case .failed(let unreadable) = KeychainSecretCommand.read(shell("echo not-json"), timeout: 5) else { return XCTFail() }
        XCTAssertEqual(unreadable, "Claude Code's sign-in is in a format UsageHUD can't read")
        let missing = KeychainSecretCommand.Invocation(executable: URL(fileURLWithPath: "/nonexistent/security"), arguments: [])
        guard case .failed(let why) = KeychainSecretCommand.read(missing, timeout: 5) else { return XCTFail() }
        XCTAssertEqual(why, "Couldn't run /usr/bin/security")
    }

    func testNoFailureCarriesTheSecret() throws {
        let file = try credentialsFile().path
        // The secret on stdout and stderr, then a failing status: neither reaches the message.
        for script in ["cat '\(file)'; cat '\(file)' >&2; exit 1", "cat '\(file)' | head -c 40; exit 0", "cat '\(file)'; exit 36"] {
            let result = KeychainSecretCommand.read(shell(script), timeout: 5)
            let text = "\(result)" + String(reflecting: result)
            XCTAssertFalse(text.contains("sk-ant"), text)
            XCTAssertFalse(text.contains(Fixtures.claudeRefresh), text)
        }
    }

    func testStdinIsClosed() {
        // `cat` with no file reads stdin: closed, it ends at once with nothing.
        let started = Date()
        let result = KeychainSecretCommand.read(.init(executable: URL(fileURLWithPath: "/bin/cat"), arguments: []), timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        guard case .failed = result else { return XCTFail("empty output is unreadable, not a hang") }
    }

    func testATimeoutStopsTheToolAndReadsAsNeedingTheOwner() {
        let started = Date()
        let result = KeychainSecretCommand.read(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]), timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "stopped, not waited for")
        guard case .needsApproval = result else { return XCTFail("\(result)") }
        // A tool that ignores SIGTERM is killed.
        let stubborn = shell("trap '' TERM; sleep 3")
        let begun = Date()
        guard case .needsApproval = KeychainSecretCommand.read(stubborn, timeout: 0.3) else { return XCTFail() }
        XCTAssertLessThan(Date().timeIntervalSince(begun), 4)
    }
}

/// Answers every request in-process: a 302 to `elsewhere.example` for the usage URLs, and
/// records whether anything ever asked for `elsewhere.example`.
final class RedirectingProtocol: URLProtocol {
    static let followed = Locked(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.host == "elsewhere.example" {
            Self.followed.set(true)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = URL(string: "https://elsewhere.example/steal")!
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TransportTests: XCTestCase {
    func testARedirectIsRefusedAndReadsAsAServerError() async {
        RedirectingProtocol.followed.set(false)
        let transport = URLSessionTransport(protocolClasses: [RedirectingProtocol.self])
        let response = await transport.send(CodexUsage.request(token: CodexToken(accessToken: "x", accountID: "acct", expiresAt: nil)))
        XCTAssertEqual(response.status, 302)
        XCTAssertFalse(RedirectingProtocol.followed.get(), "neither the bearer nor the account id followed the redirect")
    }
}
