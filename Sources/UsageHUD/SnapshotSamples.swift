import AppKit
import HUDKit
import UsageHUDKit

/// Sample records for `--snapshot` and `--snapshot-widgets`: plausible, deterministic, and
/// built without reading a credential or sending a request.
@MainActor
enum SnapshotSamples {
    /// The states `--snapshot-state` pictures.
    enum State: String, CaseIterable {
        case live, stale, loading, signedout, error, denied, off
    }

    static func records(_ state: State, now: Date) -> [Provider: ProviderRecord] {
        let claudeLive = claudeReading(at: now.addingTimeInterval(-40), now: now)
        let codexLive = codexReading(at: now.addingTimeInterval(-40), now: now)
        let attempt = now.addingTimeInterval(-40)
        switch state {
        case .live, .off:
            return [.claude: ProviderRecord(reading: claudeLive, lastAttemptAt: attempt, lastSuccessAt: attempt),
                    .codex: ProviderRecord(reading: codexLive, lastAttemptAt: attempt, lastSuccessAt: attempt)]
        case .stale:
            // Claude's token expired 2 h ago; Codex is offline and shows its session log.
            let old = now.addingTimeInterval(-2 * 3600 - 300)
            var logged = codexReading(at: now.addingTimeInterval(-25 * 60), now: now)
            logged.source = .sessionLog
            return [.claude: ProviderRecord(reading: claudeReading(at: old, now: now), lastAttemptAt: attempt, lastSuccessAt: old, problem: .expired),
                    .codex: ProviderRecord(reading: logged, lastAttemptAt: attempt, lastSuccessAt: old, problem: .network("offline"),
                                           backoffLevel: 2, retryAt: now.addingTimeInterval(200))]
        case .loading:
            return [:]
        case .signedout:
            return [.claude: ProviderRecord(lastAttemptAt: attempt, problem: .expired),
                    .codex: ProviderRecord(lastAttemptAt: attempt, problem: .signedOut)]
        case .error:
            return [.claude: ProviderRecord(lastAttemptAt: attempt, problem: .rateLimited, backoffLevel: 1, retryAt: now.addingTimeInterval(230)),
                    .codex: ProviderRecord(lastAttemptAt: attempt, problem: .server(503), backoffLevel: 1, retryAt: now.addingTimeInterval(100))]
        case .denied:
            return [.claude: ProviderRecord(lastAttemptAt: attempt, problem: .keychainDenied),
                    .codex: ProviderRecord(reading: codexLive, lastAttemptAt: attempt, lastSuccessAt: attempt)]
        }
    }

    static func claudeReading(at observed: Date, now: Date) -> UsageReading {
        UsageReading(windows: [
            UsageWindow(id: "five_hour", label: "Session", kind: .session, percentUsed: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60), windowSeconds: 18000),
            UsageWindow(id: "seven_day", label: "Weekly", kind: .weekly, percentUsed: 23, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), windowSeconds: 604800),
            UsageWindow(id: "seven_day_opus", label: "Opus weekly", kind: .model, percentUsed: 0, resetsAt: nil, windowSeconds: 604800),
            UsageWindow(id: "seven_day_model", label: "Fable 5 weekly", kind: .model, percentUsed: 78, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), windowSeconds: 604800),
        ], plan: "max", observedAt: observed)
    }

    static func codexReading(at observed: Date, now: Date) -> UsageReading {
        UsageReading(windows: [
            UsageWindow(id: "five_hour", label: "Session", kind: .session, percentUsed: 93, resetsAt: now.addingTimeInterval(47 * 60), windowSeconds: 18000),
            UsageWindow(id: "seven_day", label: "Weekly", kind: .weekly, percentUsed: 8, resetsAt: now.addingTimeInterval(6 * 86400 + 23 * 3600), windowSeconds: 604800),
        ], credits: Credits(hasCredits: true, unlimited: false, balance: 62_500), plan: "pro", observedAt: observed)
    }

    static func model(_ state: State, now: Date = Date()) -> AppModel {
        let model = AppModel(settingsURL: nil, records: records(state, now: now), now: now, pictureOnline: true)
        if state == .off { try? model.updateSettings(["codexEnabled": "off"]) }
        return model
    }

    /// Writes `usage-<size>[-<state>].png` for every declared size into `directory`.
    static func writeWidgetSnapshots(manifest: HUDManifest, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for state in [State.live, .stale, .signedout, .loading] {
            let model = model(state)
            let host = UsageWidgets.makeHost(manifest: manifest, model: model) {}
            host.presentsWindows = false
            for size in host.spec(for: ControlHost.widgetType)?.sizes ?? [] {
                let suffix = state == .live ? "" : "-\(state.rawValue)"
                let url = directory.appendingPathComponent("\(ControlHost.widgetType)-\(size.rawValue)\(suffix).png")
                try host.writeSnapshot(type: ControlHost.widgetType, size: size, to: url)
                written.append(url)
            }
        }
        return written
    }
}
