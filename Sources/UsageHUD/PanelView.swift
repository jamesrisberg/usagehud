import SwiftUI
import UsageHUDKit

/// The panel's content; `PanelController` puts it on HUD glass. One section per provider:
/// its plan and state, a plain hint when something needs the owner, and a meter per window.
struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderSection(provider: .claude, model: model)
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ProviderSection(provider: .codex, model: model)
            Spacer(minLength: 0)
            Footer(model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }
}

// MARK: - Provider

extension Provider {
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.91, green: 0.55, blue: 0.42)
        case .codex: return Color(red: 0.55, green: 0.78, blue: 0.98)
        }
    }
}

private struct ProviderSection: View {
    let provider: Provider
    @ObservedObject var model: AppModel

    var body: some View {
        let status = model.status(provider)
        let record = model.records[provider]
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(provider.tint)
                    .frame(width: 16)
                Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                if let plan = UsageFormat.plan(record?.reading?.plan), status != .off {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                StatusChip(status: status, problem: record?.problem, source: record?.reading?.source,
                           reading: model.inFlight.contains(provider))
            }
            if let hint = hint(record: record, status: status) {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content(status: status, record: record)
        }
    }

    @ViewBuilder
    private func content(status: UsageStatus, record: ProviderRecord?) -> some View {
        let meters = model.meters(provider)
        if status == .off {
            Text("Turn it on in UsageHUD's settings").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if record?.reading == nil {
            if status == .loading { PlaceholderMeters() }
        } else {
            let dimmed = status != .live
            VStack(alignment: .leading, spacing: 9) {
                if meters.isEmpty {
                    Text("No usage windows on this plan").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                ForEach(meters, id: \.id) { window in
                    MeterRow(window: window, now: model.now, dimmed: dimmed)
                }
                if let credits = record?.reading?.credits {
                    CreditsRow(credits: credits).opacity(dimmed ? 0.7 : 1)
                }
            }
        }
    }

    /// What the owner should know: the problem's hint (with when the next try is, while backing
    /// off); for a session-log reading with no problem, where the numbers came from.
    private func hint(record: ProviderRecord?, status: UsageStatus) -> String? {
        guard status != .off, let record else { return nil }
        if let problem = record.problem {
            var text = problem.hint(for: provider)
            if problem.isRemote, let retry = record.retryAt, retry > model.now {
                text += " · retrying in \(UsageFormat.duration(retry.timeIntervalSince(model.now)))"
            }
            return text
        }
        return nil
    }
}

// MARK: - Pieces

private struct StatusChip: View {
    let status: UsageStatus
    let problem: FetchProblem?
    let source: UsageReading.Source?
    let reading: Bool

    var body: some View {
        HStack(spacing: 5) {
            if reading {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
            } else if let color = dot {
                Circle().fill(color).frame(width: 6, height: 6)
                    .shadow(color: color.opacity(0.6), radius: 2)
            }
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(Color.white.opacity(0.75))
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        if reading, status == .loading { return "Reading…" }
        switch status {
        case .off: return "Off"
        case .loading: return "Reading…"
        case .live: return "Live"
        case .stale(let age):
            let prefix = source == .sessionLog ? "From log, " : ""
            return age < 60 ? "\(prefix)just now" : "\(prefix)\(UsageFormat.duration(age)) old"
        case .signedOut:
            switch problem {
            case .expired?: return "Sign-in expired"
            case .keychainNeedsApproval?: return "Needs you"
            default: return "Signed out"
            }
        case .error: return "Unavailable"
        }
    }

    private var dot: Color? {
        switch status {
        case .off, .loading: return nil
        case .live: return Color(red: 0.36, green: 0.85, blue: 0.55)
        case .stale: return Color(red: 0.98, green: 0.74, blue: 0.3)
        case .signedOut: return Color.white.opacity(0.4)
        case .error: return Color(red: 0.98, green: 0.42, blue: 0.4)
        }
    }
}

struct MeterRow: View {
    let window: UsageWindow
    let now: Date
    var dimmed = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .lineLimit(1)
                if !compact, let resets = UsageFormat.resets(window.resetsAt, now: now) {
                    Text(resets)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Text(UsageFormat.percent(window.currentPercent(at: now)))
                    .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            MeterBar(percent: window.currentPercent(at: now), dimmed: dimmed, height: compact ? 5 : 6)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MeterBar: View {
    let percent: Double?
    var dimmed = false
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if let percent, percent > 0 {
                    Capsule()
                        .fill(fill(percent))
                        .frame(width: max(height, geometry.size.width * CGFloat(min(percent, 100) / 100)))
                }
            }
        }
        .frame(height: height)
    }

    private func fill(_ percent: Double) -> Color {
        if dimmed { return Color.white.opacity(0.42) }
        if percent >= 90 { return Color(red: 0.98, green: 0.42, blue: 0.4) }
        if percent >= 70 { return Color(red: 0.98, green: 0.74, blue: 0.3) }
        return Color(red: 0.36, green: 0.82, blue: 0.6)
    }
}

struct CreditsRow: View {
    let credits: Credits
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text("Credits").font(.system(size: compact ? 11 : 12, weight: .medium))
            Spacer(minLength: 4)
            Text(text).font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        if credits.unlimited { return "Unlimited" }
        guard credits.hasCredits, let balance = credits.balance else { return "None" }
        return UsageFormat.credits(balance)
    }
}

private struct PlaceholderMeters: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(width: 90, height: 8)
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                }
            }
        }
        .accessibilityLabel("Reading usage")
    }
}

private struct Footer: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.5))
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            Button {
                model.refresh(trigger: .user)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(model.inFlight.isEmpty ? 0 : 180))
                    .animation(.easeInOut(duration: 0.4), value: model.inFlight.isEmpty)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.75))
            .disabled(!model.isOnline || !model.inFlight.isEmpty)
            .help("Read both subscriptions now")
            .accessibilityLabel("Refresh")
        }
    }

    private var text: String {
        guard model.isOnline else { return "Offline: showing the last readings" }
        let attempts = Provider.allCases.filter(model.settings.isEnabled).compactMap { model.records[$0]?.lastAttemptAt }
        let every = "every \(model.settings.pollMinutes) min"
        guard let latest = attempts.max() else { return "Checks \(every)" }
        let age = model.now.timeIntervalSince(latest)
        return "Checked \(age < 60 ? "just now" : UsageFormat.age(age)) · \(every)"
    }
}
