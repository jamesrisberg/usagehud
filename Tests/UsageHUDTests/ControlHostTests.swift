import Foundation
import HUDKit
import UsageHUDKit
import XCTest
@testable import UsageHUD

@MainActor
final class ControlHostTests: XCTestCase {
    private var host: ControlHost!
    private let now = Date(timeIntervalSince1970: 1_791_907_200)

    private func makeHost(_ state: SnapshotSamples.State) {
        let model = AppModel(settingsURL: nil, records: SnapshotSamples.records(state, now: now), now: now)
        // Never started: the router is driven directly, so no socket is created.
        host = ControlHost(model: model, panel: PanelController(model: model),
                           socketPath: NSTemporaryDirectory() + "unused-\(UUID().uuidString).sock")
    }

    override func setUp() async throws { makeHost(.live) }

    private func call(_ verb: String, _ args: [String: String] = [:]) -> [String: Any] {
        var out: [String: Any] = [:]
        host.router.handle(verb, args: args) { out = $0 }
        return out
    }

    private var panelState: [String: Any]? { (call("state")["panels"] as? [[String: Any]])?.first }

    func testHello() {
        let hello = call("hello")
        XCTAssertEqual(hello["ok"] as? Bool, true)
        XCTAssertEqual(hello["hudkit"] as? String, HUDKit.version)
        XCTAssertEqual(hello["app"] as? String, "xyz.machud.usagehud")
    }

    func testStateCarriesTheFullestMeterAndAStatusLine() {
        XCTAssertEqual(panelState?["badge"] as? String, "93%", "Codex's session is the fullest")
        XCTAssertEqual(panelState?["status"] as? String, "Claude 42% session, 23% weekly · Codex 93% session, 8% weekly")
        makeHost(.stale)
        XCTAssertEqual(panelState?["status"] as? String, "Claude 42% session, 23% weekly (stale) · Codex 93% session, 8% weekly (stale)")
        makeHost(.signedout)
        XCTAssertNil(panelState?["badge"])
        XCTAssertEqual(panelState?["status"] as? String, "Claude signed out · Codex signed out")
    }

    func testUsageReportsReadingsAndAges() throws {
        let reply = call("action", ["name": "usage"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let providers = try XCTUnwrap(reply["providers"] as? [String: Any])
        let claude = try XCTUnwrap(providers["claude"] as? [String: Any])
        XCTAssertEqual(claude["status"] as? String, "live")
        let reading = try XCTUnwrap(claude["lastReading"] as? [String: Any])
        XCTAssertEqual(reading["ageSeconds"] as? Int, 40)
        XCTAssertEqual(reading["plan"] as? String, "max")
        let windows = try XCTUnwrap(reading["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.first?["resetsInSeconds"] as? Int, 2 * 3600 + 13 * 60)
        let codex = try XCTUnwrap(providers["codex"] as? [String: Any])
        XCTAssertEqual(((codex["lastReading"] as? [String: Any])?["credits"] as? [String: Any])?["balance"] as? Double, 62_500)

        makeHost(.stale)
        let stale = try XCTUnwrap((call("action", ["name": "usage"])["providers"] as? [String: Any])?["claude"] as? [String: Any])
        XCTAssertEqual(stale["status"] as? String, "stale")
        XCTAssertEqual(stale["problem"] as? String, "expired")
        XCTAssertEqual(stale["hint"] as? String, "Open Claude Code to refresh your sign-in")
    }

    func testRefreshValidatesAndIsANoOpOffline() {
        XCTAssertEqual(call("action", ["name": "refresh", "provider": "gemini"])["ok"] as? Bool, false)
        let reply = call("action", ["name": "refresh"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["online"] as? Bool, false, "a model without a service reads nothing")
        XCTAssertEqual(call("settings", ["action": "set", "codexEnabled": "off"])["ok"] as? Bool, true)
        XCTAssertEqual(call("action", ["name": "refresh", "provider": "codex"])["ok"] as? Bool, false, "codex is off")
        XCTAssertEqual(panelState?["status"] as? String, "Claude 42% session, 23% weekly")
    }

    func testSettingsSetValidates() {
        XCTAssertEqual(call("settings", ["action": "set", "pollMinutes": "15"])["ok"] as? Bool, true)
        XCTAssertEqual(host.model.settings.pollMinutes, 15)
        XCTAssertEqual(call("settings", ["action": "set", "pollMinutes": "0"])["ok"] as? Bool, false)
        XCTAssertEqual(call("settings", ["action": "set", "claudeEnabled": "maybe"])["ok"] as? Bool, false)
    }

    func testUnknownPanelAndAction() {
        XCTAssertEqual(call("panel", ["id": "nope", "action": "show"])["ok"] as? Bool, false)
        XCTAssertEqual(call("action", ["name": "say"])["ok"] as? Bool, false)
    }
}

@MainActor
final class WidgetHostTests: XCTestCase {
    private var control: ControlHost!
    private var widgets: HUDWidgetHost!
    private var opened = 0

    override func setUp() async throws {
        let model = SnapshotSamples.model(.live)
        control = ControlHost(model: model, panel: PanelController(model: model),
                              socketPath: NSTemporaryDirectory() + "unused-\(UUID().uuidString).sock")
        widgets = UsageWidgets.makeHost(manifest: ControlHost.builtinManifest, model: model) { [unowned self] in opened += 1 }
        widgets.presentsWindows = false
        control.router.widgetHost = widgets
    }

    private func widget(_ args: [String: String]) -> [String: Any] {
        var response: [String: Any] = [:]
        control.router.handle("widget", args: args) { response = $0 }
        return response
    }

    func testTheUsageTypeIsRegisteredWithBothSizes() {
        XCTAssertEqual(widgets.types, ["usage"])
        XCTAssertEqual(widgets.spec(for: "usage")?.sizes, [.small, .medium])
    }

    func testInstanceLifecycle() {
        let created = widget(["action": "create", "instance": "a", "type": "usage", "frame": "40,40,170,170"])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        XCTAssertEqual(widget(["action": "update", "instance": "a", "size": "medium", "frame": "40,40,356,170"])["ok"] as? Bool, true)
        XCTAssertEqual(widget(["action": "remove", "instance": "a"])["removed"] as? String, "a")
    }

    func testSnapshotsRenderEveryStateAndSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-widgets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try SnapshotSamples.writeWidgetSnapshots(manifest: ControlHost.builtinManifest, to: dir)
        XCTAssertEqual(files.count, 8)
        for file in files { XCTAssertGreaterThan((try? Data(contentsOf: file))?.count ?? 0, 1000, file.lastPathComponent) }
    }
}
