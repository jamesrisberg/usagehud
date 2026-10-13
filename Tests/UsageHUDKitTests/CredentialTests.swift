import Foundation
import XCTest
@testable import UsageHUDKit

final class CredentialTests: XCTestCase {
    func testClaudeCredentialsKeepOnlyTheAccessTokenExpiryAndPlan() throws {
        let expiry = Fixtures.now.addingTimeInterval(3600)
        let token = try XCTUnwrap(ClaudeToken.parse(Fixtures.claudeCredentials(expiresAt: expiry)))
        XCTAssertEqual(token.accessToken, Fixtures.claudeAccess)
        XCTAssertEqual(token.expiresAt?.timeIntervalSince1970 ?? 0, expiry.timeIntervalSince1970, accuracy: 0.001, "expiresAt is in milliseconds")
        XCTAssertEqual(token.subscriptionType, "max")
        XCTAssertFalse(token.isExpired(at: Fixtures.now))
        XCTAssertTrue(token.isExpired(at: expiry.addingTimeInterval(-30)), "within the minute's leeway")
        XCTAssertTrue(token.isExpired(at: expiry.addingTimeInterval(10)))
    }

    func testNoDescriptionOfATokenContainsASecret() throws {
        let claude = try XCTUnwrap(ClaudeToken.parse(Fixtures.claudeCredentials(expiresAt: Fixtures.now)))
        let jwt = Fixtures.jwt(expiresAt: Fixtures.now)
        let codex = try XCTUnwrap(CodexToken.parse(Fixtures.codexAuth(access: jwt)))
        for text in [String(describing: claude), String(reflecting: claude), "\(claude)", dumped(claude),
                     String(describing: codex), String(reflecting: codex), dumped(codex)] {
            XCTAssertFalse(text.contains(Fixtures.claudeAccess), text)
            XCTAssertFalse(text.contains(Fixtures.claudeRefresh), text)
            XCTAssertFalse(text.contains(jwt), text)
            XCTAssertFalse(text.contains(Fixtures.codexRefresh), text)
            XCTAssertFalse(text.contains("acct-fixture"), text)
        }
    }

    private func dumped(_ value: Any) -> String {
        var out = ""
        dump(value, to: &out)
        return out
    }

    func testClaudeCredentialsThatAreNotUsable() {
        XCTAssertNil(ClaudeToken.parse(Data("{}".utf8)))
        XCTAssertNil(ClaudeToken.parse(Data(#"{"claudeAiOauth": {"accessToken": ""}}"#.utf8)))
        XCTAssertNil(ClaudeToken.parse(Data("not json".utf8)))
        let noExpiry = ClaudeToken.parse(Data(#"{"claudeAiOauth": {"accessToken": "a"}}"#.utf8))
        XCTAssertEqual(noExpiry?.isExpired(at: Fixtures.now), false, "a token without an expiry is tried")
    }

    func testCodexAuthReadsTheJWTExpiry() throws {
        let expiry = Fixtures.now.addingTimeInterval(7200)
        let token = try XCTUnwrap(CodexToken.parse(Fixtures.codexAuth(access: Fixtures.jwt(expiresAt: expiry))))
        XCTAssertEqual(token.expiresAt, expiry)
        XCTAssertEqual(token.accountID, "acct-fixture")
        XCTAssertFalse(token.isExpired(at: Fixtures.now))
        XCTAssertTrue(token.isExpired(at: expiry))
        XCTAssertNil(CodexToken.jwtExpiry("opaque-token"))
        XCTAssertNil(CodexToken.parse(Data(#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-x", "tokens": null}"#.utf8)),
                     "an API key login has no subscription usage")
    }

    func testCodexAuthFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = CodexAuthFile(codexHome: dir)
        guard case .missing = source.read() else { return XCTFail("no file is signed out") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixtures.codexAuth(access: Fixtures.jwt(expiresAt: Fixtures.now)).write(to: dir.appendingPathComponent("auth.json"))
        guard case .found(let token) = source.read() else { return XCTFail("the file's token") }
        XCTAssertEqual(token.accountID, "acct-fixture")
    }

    func testKeychainItemNames() {
        XCTAssertEqual(ClaudeCredentialsStore.keychainService(environment: [:]), "Claude Code-credentials")
        let custom = ClaudeCredentialsStore.keychainService(environment: ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-work"])
        XCTAssertTrue(custom.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(custom.count, "Claude Code-credentials-".count + 8)
        XCTAssertEqual(ClaudeCredentialsStore.keychainService(environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]), "Claude Code-credentials")
        XCTAssertEqual(ClaudeCredentialsStore.keychainAccount(environment: ["USER": "jrisberg"]), "jrisberg")
        XCTAssertEqual(ClaudeCredentialsStore.keychainAccount(environment: ["USER": "a b"]), "claude-code-user")
        XCTAssertEqual(ClaudeCredentialsStore.plaintextFile(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"]).path, "/tmp/cc/.credentials.json")
    }

    func testRequestsCarryOnlyWhatTheReferenceSends() throws {
        let claude = ClaudeUsage.request(token: ClaudeToken(accessToken: "c-token", expiresAt: nil, subscriptionType: nil))
        XCTAssertEqual(claude.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(claude.httpMethod, "GET")
        XCTAssertNil(claude.httpBody)
        XCTAssertEqual(claude.allHTTPHeaderFields, ["Authorization": "Bearer c-token", "Content-Type": "application/json",
                                                    "anthropic-beta": "oauth-2025-04-20"])
        let codex = CodexUsage.request(token: CodexToken(accessToken: "x-token", accountID: "acct", expiresAt: nil))
        XCTAssertEqual(codex.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(codex.httpMethod, "GET")
        XCTAssertNil(codex.httpBody)
        XCTAssertEqual(codex.allHTTPHeaderFields, ["Authorization": "Bearer x-token", "Content-Type": "application/json",
                                                   "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
                                                   "Chatgpt-Account-Id": "acct"])
    }
}
