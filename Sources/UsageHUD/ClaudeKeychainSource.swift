import Foundation
import LocalAuthentication
import Security
import UsageHUDKit

/// Reads Claude Code's OAuth credentials the way Claude Code stores them on macOS: the
/// plaintext `<config>/.credentials.json` when it exists, else the login Keychain's generic
/// password `Claude Code-credentials` (account: the login name). Read-only: this type only ever
/// calls `SecItemCopyMatching`.
///
/// The first read shows the Keychain's prompt ("UsageHUD wants to use your confidential
/// information"); "Always Allow" lets later reads through silently. A read with `allowPrompt`
/// false asks the Keychain to fail rather than prompt (`errSecInteractionNotAllowed`), which
/// UsageHUD reports as "Refresh to read Claude Code's sign-in".
struct ClaudeKeychainSource: ClaudeTokenSource {
    let service: String
    let account: String
    let plaintextFile: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        service = ClaudeCredentialsStore.keychainService(environment: environment)
        account = ClaudeCredentialsStore.keychainAccount(environment: environment)
        plaintextFile = ClaudeCredentialsStore.plaintextFile(environment: environment)
    }

    /// Keychain reads wait for the owner while the prompt is up, so they run on their own queue.
    private static let queue = DispatchQueue(label: "xyz.machud.usagehud.keychain")

    func read(allowPrompt: Bool) async -> CredentialLookup<ClaudeToken> {
        if let data = try? Data(contentsOf: plaintextFile), let token = ClaudeToken.parse(data) { return .found(token) }
        return await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: readKeychain(allowPrompt: allowPrompt)) }
        }
    }

    private func readKeychain(allowPrompt: Bool) -> CredentialLookup<ClaudeToken> {
        var lookup = copy(account: account, allowPrompt: allowPrompt)
        // An item saved under another account name (a renamed user) still belongs to this service.
        if case .missing = lookup { lookup = copy(account: nil, allowPrompt: allowPrompt) }
        return lookup
    }

    private func copy(account: String?, allowPrompt: Bool) -> CredentialLookup<ClaudeToken> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = ClaudeToken.parse(data) else {
                return .failed("Claude Code's sign-in is in a format UsageHUD can't read")
            }
            return .found(token)
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        case errSecInteractionNotAllowed:
            return allowPrompt ? .failed("The Keychain is locked") : .needsApproval
        default:
            return .failed("Keychain error \(status)")
        }
    }
}
