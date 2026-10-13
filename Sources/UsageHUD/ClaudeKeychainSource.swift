import Foundation
import Security
import UsageHUDKit

/// Claude Code's credentials store on macOS, read the way Claude Code keeps it:
///
/// 1. the plaintext `<config>/.credentials.json`, when it exists and holds a token;
/// 2. else the login Keychain's generic password `Claude Code-credentials` (account: the login
///    name), whose secret is read with `/usr/bin/security find-generic-password -s <service>
///    -a <account> -w` (`KeychainSecretCommand`). Claude Code writes the item with `security`,
///    so the item's access list already trusts that tool: no prompt, and nothing depends on
///    UsageHUD's own signature.
///
/// `stamp()` reads only the item's attributes (`SecItemCopyMatching` with
/// `kSecReturnAttributes`, never its data), which the Keychain gives without asking; its
/// modification date tells the service when the secret is worth reading again.
struct ClaudeKeychainSource: ClaudeTokenSource {
    let service: String
    let account: String
    let plaintextFile: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        service = ClaudeCredentialsStore.keychainService(environment: environment)
        account = ClaudeCredentialsStore.keychainAccount(environment: environment)
        plaintextFile = ClaudeCredentialsStore.plaintextFile(environment: environment)
    }

    /// How long a scheduled read waits for `security`; the owner's refresh waits longer.
    static let timeout: TimeInterval = 10
    static let patientTimeout: TimeInterval = 60

    func stamp() async -> StampLookup {
        if let modified = usableFileDate() { return .present(CredentialStamp(location: .file, modified: modified)) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: keychainStamp()) }
        }
    }

    func read(_ location: CredentialStamp.Location, patient: Bool) async -> CredentialLookup<ClaudeToken> {
        switch location {
        case .file:
            guard var data = try? Data(contentsOf: plaintextFile) else { return .missing }
            defer { data.resetBytes(in: 0..<data.count) }
            return ClaudeToken.parse(data).map { .found($0) } ?? .missing
        case .keychain:
            let invocation = KeychainSecretCommand.Invocation.findClaudeCredentials(service: service, account: account)
            let timeout = patient ? Self.patientTimeout : Self.timeout
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: KeychainSecretCommand.read(invocation, timeout: timeout))
                }
            }
        }
    }

    /// The plaintext file's modification date, when it exists and holds a token.
    private func usableFileDate() -> Date? {
        guard var data = try? Data(contentsOf: plaintextFile) else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        guard ClaudeToken.parse(data) != nil else { return nil }
        return (try? plaintextFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// The Keychain item's attributes only: whether it exists and when it last changed.
    private func keychainStamp() -> StampLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let attributes = result as? [String: Any]
            let modified = attributes?[kSecAttrModificationDate as String] as? Date
                ?? attributes?[kSecAttrCreationDate as String] as? Date
            return .present(CredentialStamp(location: .keychain, modified: modified))
        case errSecItemNotFound:
            return .missing
        default:
            return .failed("The Keychain could not be searched (\(status))")
        }
    }
}
