import AppKit
import HUDKit
import SwiftUI
import UsageHUDKit

/// The `usage` desktop widget: the same meters as the panel, compact. Small: Claude's session
/// and weekly windows and Codex's tightest window. Medium: both providers side by side.
/// Tapping it opens the panel. It reads the panel's model, so it needs no settings of its own.
struct UsageWidgetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var context: HUDWidgetContext

    var body: some View {
        Group {
            switch context.size {
            case .small: small
            default: medium
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { context.openApp() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
    }

    private var shown: [Provider] { Provider.allCases.filter(model.settings.isEnabled) }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Usage").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if shown.isEmpty {
                Spacer(minLength: 0)
                Text("Both subscriptions are off").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            ForEach(shown, id: \.self) { provider in
                WidgetProvider(provider: provider, model: model, limit: provider == .claude && shown.count > 1 ? 2 : (shown.count > 1 ? 1 : 3))
            }
            Spacer(minLength: 0)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            if shown.isEmpty {
                Text("Both subscriptions are off. Turn one on in UsageHUD's settings")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(shown, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 7) {
                    WidgetProvider(provider: provider, model: model, limit: 3)
                    if let credits = model.records[provider]?.reading?.credits {
                        CreditsRow(credits: credits, compact: true).opacity(model.status(provider) == .live ? 1 : 0.7)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// One provider in the widget: a name line with its state, then up to `limit` meters (the
/// fullest first when they do not all fit).
private struct WidgetProvider: View {
    let provider: Provider
    @ObservedObject var model: AppModel
    let limit: Int

    var body: some View {
        let status = model.status(provider)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: provider.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(provider.tint)
                Text(provider.displayName).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 2)
                Text(caption(status)).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.55)).monospacedDigit()
                    .lineLimit(1)
            }
            let meters = picked
            if meters.isEmpty {
                Text(empty(status)).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.55)).lineLimit(2)
            }
            ForEach(meters, id: \.id) { window in
                MeterRow(window: window, now: model.now, dimmed: status != .live, compact: true)
            }
        }
    }

    private var picked: [UsageWindow] {
        let all = model.meters(provider)
        guard all.count > limit else { return all }
        let now = model.now
        let keep = Set(all.sorted { ($0.currentPercent(at: now) ?? 0) > ($1.currentPercent(at: now) ?? 0) }.prefix(limit).map(\.id))
        return all.filter { keep.contains($0.id) }
    }

    private func caption(_ status: UsageStatus) -> String {
        switch status {
        case .live: return UsageFormat.plan(model.records[provider]?.reading?.plan) ?? ""
        case .stale(let age): return age < 60 ? "just now" : "\(UsageFormat.duration(age)) old"
        case .loading: return "…"
        case .signedOut: return "signed out"
        case .error: return "unavailable"
        case .off: return "off"
        }
    }

    private func empty(_ status: UsageStatus) -> String {
        switch status {
        case .signedOut: return model.records[provider]?.problem?.hint(for: provider) ?? "Signed out"
        case .error: return model.records[provider]?.problem?.hint(for: provider) ?? "Unavailable"
        case .loading: return "Reading usage…"
        default: return "No usage windows"
        }
    }
}

/// The widget host: registers the `usage` type; a tap on a widget opens the panel.
@MainActor
enum UsageWidgets {
    static func makeHost(manifest: HUDManifest, model: AppModel, openPanel: @escaping () -> Void) -> HUDWidgetHost {
        let host = HUDWidgetHost(manifest: manifest)
        host.register(ControlHost.widgetType) { context in
            UsageWidgetView(model: model, context: context)
        }
        host.onOpen = { _ in openPanel() }
        return host
    }
}
