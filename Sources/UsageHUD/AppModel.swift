import Foundation
import UsageHUDKit

/// What the panel and the widgets show: the settings, each provider's record, and the clock
/// the ages are measured against. Reads go through `UsageService` off the main thread; this
/// model polls it on the settings' interval.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var records: [Provider: ProviderRecord] = [:]
    @Published private(set) var inFlight: Set<Provider> = []
    /// Ages and "resets in" are measured against this; it ticks every 30 s.
    @Published private(set) var now: Date

    let settingsURL: URL?
    /// Nil without network or credentials: tests, snapshots and `USAGEHUD_OFFLINE`.
    private let service: UsageService?
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    /// Called after every change MacHUD can see (the badge and status line).
    var onChange: (() -> Void)?

    /// `settingsURL` nil keeps the settings in memory (tests). `pictureOnline` draws a model
    /// without a service as if it had one (snapshots of the live panel).
    init(settingsURL: URL?, service: UsageService? = nil, records: [Provider: ProviderRecord] = [:], now: Date = Date(),
         pictureOnline: Bool = false) {
        self.settingsURL = settingsURL
        self.service = service
        self.pictureOnline = pictureOnline
        self.records = records
        self.now = now
        settings = settingsURL.map(AppSettings.load(from:)) ?? AppSettings()
    }

    private let pictureOnline: Bool

    /// Whether this model reads at all (it has a service).
    var canRead: Bool { service != nil }

    /// What the refresh button and the footer picture.
    var isOnline: Bool { canRead || pictureOnline }

    // MARK: Polling

    /// Loads the cached readings, then reads every enabled provider and polls from then on.
    func start() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        guard let service else { return }
        Task {
            let cached = await service.snapshot()
            records = cached
            onChange?()
            refresh(trigger: .scheduled)
        }
        reschedulePoll()
    }

    func stop() {
        pollTimer?.invalidate()
        clockTimer?.invalidate()
    }

    private func reschedulePoll() {
        pollTimer?.invalidate()
        guard service != nil else { return }
        let interval = TimeInterval(settings.pollMinutes * 60)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh(trigger: .scheduled) }
        }
        pollTimer?.tolerance = interval * 0.1
    }

    /// Reads `providers` (default: every enabled one) unless the trigger says to wait. Returns
    /// the providers a read was started for.
    @discardableResult
    func refresh(_ providers: [Provider]? = nil, trigger: RefreshTrigger) -> [Provider] {
        guard let service else { return [] }
        let targets = (providers ?? settings.enabledProviders).filter { settings.isEnabled($0) && !inFlight.contains($0) }
        for provider in targets {
            inFlight.insert(provider)
            Task {
                let record = await service.refresh(provider, trigger: trigger)
                records[provider] = record
                inFlight.remove(provider)
                now = Date()
                onChange?()
            }
        }
        if !targets.isEmpty { onChange?() }
        return targets
    }

    /// The panel opened: read whatever is over a minute old.
    func panelOpened() { refresh(trigger: .panelOpen) }

    // MARK: Settings

    func updateSettings(_ values: [String: String]) throws {
        let next = try settings.applying(values)
        if let settingsURL { try next.save(to: settingsURL) }
        let enabledBefore = Set(settings.enabledProviders)
        let pollChanged = next.pollMinutes != settings.pollMinutes
        settings = next
        if pollChanged { reschedulePoll() }
        let newlyEnabled = next.enabledProviders.filter { !enabledBefore.contains($0) }
        if !newlyEnabled.isEmpty { refresh(newlyEnabled, trigger: .panelOpen) }
        onChange?()
    }

    // MARK: What it shows

    var staleAfter: TimeInterval { UsageStatus.staleAfter(pollMinutes: settings.pollMinutes) }

    func status(_ provider: Provider) -> UsageStatus {
        UsageStatus.of(records[provider], enabled: settings.isEnabled(provider), now: now, staleAfter: staleAfter)
    }

    func meters(_ provider: Provider) -> [UsageWindow] { records[provider]?.reading?.meterWindows ?? [] }

    /// The fullest meter across the shown providers, for MacHUD's dock badge: `42%`. A window
    /// that has reset since its reading no longer counts.
    var badge: String? {
        let values = Provider.allCases.filter(settings.isEnabled).flatMap { meters($0) }.compactMap { $0.currentPercent(at: now) }
        return values.max().map { UsageFormat.percent($0) }
    }

    /// One line for MacHUD: `Claude 42% session, 23% weekly · Codex 0% weekly`.
    var statusLine: String {
        let parts = Provider.allCases.filter(settings.isEnabled).map { provider -> String in
            let name = provider.displayName
            switch status(provider) {
            case .off: return "\(name) off"
            case .loading: return "\(name) loading"
            case .signedOut: return "\(name) signed out"
            case .error: return "\(name) unavailable"
            case .live, .stale:
                let windows = meters(provider).filter { ($0.kind == .session || $0.kind == .weekly) && !$0.hasReset(at: now) }
                let numbers = windows.map { "\(UsageFormat.percent($0.percentUsed)) \($0.label.lowercased())" }.joined(separator: ", ")
                let stale = status(provider) == .live ? "" : " (stale)"
                return "\(name) \(numbers.isEmpty ? "no windows" : numbers)\(stale)"
            }
        }
        return parts.isEmpty ? "Nothing to show" : parts.joined(separator: " · ")
    }

    /// The `usage` action's reply: every provider's status, readings and their ages.
    var usageJSON: [String: Any] {
        var providers: [String: Any] = [:]
        for provider in Provider.allCases {
            let record = records[provider] ?? ProviderRecord()
            let status = status(provider)
            var entry: [String: Any] = ["enabled": settings.isEnabled(provider), "status": status.code,
                                        "inFlight": inFlight.contains(provider)]
            if let reading = record.reading {
                var r: [String: Any] = ["source": reading.source.rawValue, "observedAt": iso(reading.observedAt),
                                        "ageSeconds": Int(max(0, now.timeIntervalSince(reading.observedAt))),
                                        "windows": reading.windows.map { window(json: $0) }]
                if let plan = reading.plan { r["plan"] = plan }
                if let credits = reading.credits {
                    var c: [String: Any] = ["hasCredits": credits.hasCredits, "unlimited": credits.unlimited]
                    if let balance = credits.balance { c["balance"] = balance }
                    r["credits"] = c
                }
                entry["lastReading"] = r
            }
            if let problem = record.problem {
                entry["problem"] = problem.code
                entry["hint"] = problem.hint(for: provider)
            }
            if let at = record.lastAttemptAt { entry["lastAttemptAt"] = iso(at) }
            if let at = record.retryAt, at > now { entry["retryAt"] = iso(at) }
            providers[provider.rawValue] = entry
        }
        return ["ok": true, "online": canRead, "providers": providers]
    }

    private func window(json window: UsageWindow) -> [String: Any] {
        var w: [String: Any] = ["id": window.id, "label": window.label, "kind": window.kind.rawValue]
        if let p = window.percentUsed { w["percentUsed"] = p }
        if window.hasReset(at: now) { w["hasReset"] = true }
        if let r = window.resetsAt {
            w["resetsAt"] = iso(r)
            w["resetsInSeconds"] = Int(max(0, r.timeIntervalSince(now)))
        }
        return w
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
