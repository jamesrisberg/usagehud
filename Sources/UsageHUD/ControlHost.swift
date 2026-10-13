import AppKit
import HUDKit
import UsageHUDKit

/// UsageHUD's side of the MacHUD contract: serves the control socket at
/// `~/Library/Application Support/MacHUD/sockets/usagehud.sock` through HUDKit's router.
/// See docs/CONTRACT.md for the verbs.
@MainActor
final class ControlHost: HUDPanelHost {
    nonisolated static let panelID = "main"
    /// The desktop widget type: a `kind: widget` manifest panel, served by `HUDWidgetHost` (UsageWidget.swift).
    nonisolated static let widgetType = "usage"
    static let actions = ["refresh", "usage", "show", "hide", "toggle"]
    static let verbs = ["show", "hide", "toggle", "frame", "refresh", "usage"]

    /// Used when running outside a bundle (`swift run`, tests); mirrors Resources/machud.json.
    static let builtinManifest = HUDManifest(id: "xyz.machud.usagehud", name: "UsageHUD", socket: "usagehud", panels: [
        HUDManifest.Panel(id: panelID, title: "Usage", symbol: "gauge.with.dots.needle.50percent",
                          defaultSize: HUDSize(PanelController.size),
                          verbs: verbs, settingsSchema: "settings.json", kind: .hover, order: 6),
        HUDManifest.Panel(id: widgetType, title: "Usage", symbol: "gauge.with.dots.needle.50percent", kind: .widget,
                          widget: HUDWidgetSpec(sizes: [.small, .medium], defaultSize: .small, multiple: true, refresh: 60)),
    ], iconName: "gauge.with.dots.needle.50percent")

    let manifest: HUDManifest
    let server: HUDSocketServer
    private(set) var router: HUDControlRouter!
    let model: AppModel
    let panel: PanelController
    private var lastPublished: String?

    init(model: AppModel, panel: PanelController, socketPath: String? = nil) {
        self.model = model
        self.panel = panel
        manifest = HUDManifest.main ?? Self.builtinManifest
        server = HUDSocketServer(path: socketPath ?? HUDSocket.path(for: AppEnvironment.socketName(default: manifest.socket)),
                                 label: "usagehud.socket")
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
    }

    func start() {
        router.install()
        if !server.start() { NSLog("UsageHUD: control socket failed to start at %@", server.path) }
    }

    func stop() { server.stop() }

    /// Pushes `state` when anything MacHUD shows changed (visibility, the badge, the status line).
    func publishIfChanged() {
        let signature = panelStates.map { "\($0.visible)|\($0.badge ?? "")|\($0.status ?? "")" }.joined()
        guard signature != lastPublished else { return }
        lastPublished = signature
        router.publishState()
    }

    // MARK: - HUDPanelHost

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    /// `badge` is the fullest meter (`42%`); `status` one line per provider.
    var panelStates: [HUDPanelState] {
        [HUDPanelState(id: Self.panelID, visible: panel.isShown, badge: model.badge, status: model.statusLine)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    func showPanel(_ id: String) throws { try check(id); panel.show() }
    func hidePanel(_ id: String) throws { try check(id); panel.hide() }

    func showPanel(_ id: String, options: [String: String]) throws {
        try check(id)
        panel.show(HUDPanelTransition(options))
    }

    func hidePanel(_ id: String, options: [String: String]) throws {
        try check(id)
        panel.hide(HUDPanelTransition(options))
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 100, frame.height >= 60 else { throw HUDControlError.invalid("frame too small") }
        panel.setFrame(frame)
    }

    // MARK: Settings

    func settings() -> [String: Any] { model.settings.json }

    func updateSettings(_ values: [String: String]) throws {
        do {
            try model.updateSettings(values)
        } catch let error as AppSettings.SettingsError {
            throw HUDControlError.invalid(error.description)
        }
        publishIfChanged()
    }

    // MARK: Actions

    /// Runs on the main thread and answers at once: `refresh` replies when the reads have
    /// started and publishes `state` when each lands.
    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        switch name {
        case "refresh":
            let raw = (args["provider"] ?? "all").lowercased()
            let providers: [Provider]?
            if raw == "all" || raw.isEmpty {
                providers = nil
            } else if let provider = Provider(rawValue: raw) {
                providers = [provider]
            } else {
                done(["ok": false, "error": "provider must be claude, codex or all"])
                return
            }
            if let one = providers?.first, !model.settings.isEnabled(one) {
                done(["ok": false, "error": "\(one.displayName) is off (settings set \(one.rawValue)Enabled=on)"])
                return
            }
            guard model.canRead else {
                done(["ok": true, "started": [String](), "online": false])
                return
            }
            let started = model.refresh(providers, trigger: .user)
            done(["ok": true, "started": started.map(\.rawValue), "online": true])
        case "usage":
            done(model.usageJSON)
        case "show", "hide", "toggle":
            switch name {
            case "show": panel.show()
            case "hide": panel.hide()
            default: panel.toggle()
            }
            done(["ok": true, "visible": panel.isShown])
        default:
            done(["ok": false, "error": "unknown action \(name) (\(Self.actions.joined(separator: ", ")))"])
        }
    }

    func quit() { NSApp.terminate(nil) }
}
