import Foundation

/// Isolation switches for tests and parallel instances (docs/CONTRACT.md):
///
/// - `USAGEHUD_HOME`: base directory for everything UsageHUD writes (settings in
///   `<home>/preferences.json`); default `~/Library/Application Support/UsageHUD`.
/// - `USAGEHUD_SOCKET`: socket name under MacHUD's sockets directory; default `usagehud`.
/// - `USAGEHUD_NO_HOTKEYS`: set to skip registering global hotkeys.
enum AppEnvironment {
    static let environment = ProcessInfo.processInfo.environment

    static var isolatedHome: String? { nonEmpty("USAGEHUD_HOME") }

    static var baseDirectory: URL {
        if let home = isolatedHome {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageHUD", isDirectory: true)
    }

    static var settingsURL: URL { baseDirectory.appendingPathComponent("preferences.json") }

    static func socketName(default name: String) -> String { nonEmpty("USAGEHUD_SOCKET") ?? name }

    static var hotKeysEnabled: Bool { environment["USAGEHUD_NO_HOTKEYS"] == nil }

    private static func nonEmpty(_ key: String) -> String? {
        environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}
