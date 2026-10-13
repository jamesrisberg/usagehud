import AppKit
import HUDKit
import UsageHUDKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var control: ControlHost!
    private var statusItem: NSStatusItem!
    /// The desktop widgets (`usage`); kept for the app's lifetime.
    private var widgets: HUDWidgetHost!
    static let toggleHotKey = HUDHotKey(key: "u", modifiers: ["control", "option"])

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no main menu, so without this ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing in text fields.
        HUDEditMenu.install(appName: "UsageHUD")
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }

        // `--snapshot-widgets <dir>`: render the widget at each size and state from sample
        // readings, print the paths and quit. Nothing else is set up.
        if let directory = value("--snapshot-widgets") {
            do {
                let files = try SnapshotSamples.writeWidgetSnapshots(manifest: HUDManifest.main ?? ControlHost.builtinManifest,
                                                                     to: URL(fileURLWithPath: directory))
                files.forEach { print($0.path) }
            } catch {
                FileHandle.standardError.write(Data("UsageHUD: widget snapshot failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
            return
        }

        // `--snapshot <path.png> [--snapshot-state live|stale|loading|signedout|error|denied|off]`:
        // the panel over sample readings, written once it settles; then quit. A snapshot only
        // draws: no control socket (a running app owns that name, and starting it announces the
        // app to MacHUD), no hotkey, no menu bar item, and no credential read or request.
        if let path = value("--snapshot") {
            let state = value("--snapshot-state").flatMap(SnapshotSamples.State.init(rawValue:)) ?? .live
            model = SnapshotSamples.model(state)
            panel = PanelController(model: model)
            panel.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                do {
                    try self?.panel.writeSnapshot(to: URL(fileURLWithPath: path))
                    print(path)
                } catch {
                    FileHandle.standardError.write(Data("UsageHUD: snapshot failed: \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
            return
        }

        model = Self.makeModel()
        panel = PanelController(model: model)
        control = ControlHost(model: model, panel: panel)
        // Before start(): MacHUD sends `widget sync` as soon as it connects.
        widgets = UsageWidgets.makeHost(manifest: control.manifest, model: model) { [weak self] in self?.panel.show() }
        control.router.widgetHost = widgets
        model.onChange = { [weak self] in self?.control.publishIfChanged() }
        panel.onStateChange = { [weak self] in self?.control.publishIfChanged() }
        control.start()
        setupStatusItem()
        // Menu bar consolidation: MacHUD shows this menu inside its own (`menu`, `menu-invoke`)
        // and the icon hides while it does. The `menuBar.consumed` opt-out is kept in
        // <home>/menubar.json, so it follows USAGEHUD_HOME.
        control.router.menuProvider = { [weak self] in self?.statusItem.menu }
        HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id, store: .home(AppEnvironment.baseDirectory))
        if AppEnvironment.hotKeysEnabled {
            if HUDHotKeyCenter.shared.register(Self.toggleHotKey, onPress: { [weak self] in self?.panel.toggle() }) == nil {
                NSLog("UsageHUD: %@ is taken by another app", Self.toggleHotKey.display)
            }
        }
        model.start()
    }

    /// The live model: reads Claude Code's and Codex's sign-ins and their usage endpoints.
    /// `USAGEHUD_OFFLINE` keeps it to the cached readings (no credential, no request).
    private static func makeModel() -> AppModel {
        if AppEnvironment.offline {
            return AppModel(settingsURL: AppEnvironment.settingsURL,
                            records: UsageCache.load(from: AppEnvironment.cacheURL).providerRecords)
        }
        let codexHome = CodexHome.directory()
        let service = UsageService(transport: URLSessionTransport(), claudeSource: ClaudeKeychainSource(),
                                   codexSource: CodexAuthFile(codexHome: codexHome),
                                   sessionLog: CodexSessionLog(codexHome: codexHome), cacheURL: AppEnvironment.cacheURL)
        return AppModel(settingsURL: AppEnvironment.settingsURL, service: service)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        control?.stop()
    }

    // MARK: - Status item

    private enum Tag: Int { case toggle = 1, refresh }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // MenuBarIcon.png from hudkit/scripts/hud-icon.sh; the symbol under `swift run`.
        statusItem.button?.image = HUDStatusIcon.image(fallbackSymbol: "gauge.with.dots.needle.50percent", accessibilityDescription: "UsageHUD")
        let menu = NSMenu()
        menu.delegate = self
        // menuNeedsUpdate decides what is enabled (Refresh Now needs a live model).
        menu.autoenablesItems = false
        let toggle = NSMenuItem(title: "Show Usage", action: #selector(togglePanel), keyEquivalent: "u")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.tag = Tag.toggle.rawValue
        toggle.target = self
        menu.addItem(toggle)
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "")
        refresh.tag = Tag.refresh.rawValue
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit UsageHUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch Tag(rawValue: item.tag) {
            case .toggle: item.title = panel.isShown ? "Hide Usage" : "Show Usage"
            case .refresh: item.isEnabled = model.canRead
            case nil: break
            }
        }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func refreshNow() { model.refresh(trigger: .user) }
}
