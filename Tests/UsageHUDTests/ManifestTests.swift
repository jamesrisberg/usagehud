import Foundation
import HUDKit
import XCTest
@testable import UsageHUD
import UsageHUDKit

/// The shipped machud.json and settings.json are what MacHUD reads without launching
/// UsageHUD; keep them valid and in step with the code.
final class ManifestTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UsageHUD/Resources")
    }

    private func manifest() throws -> HUDManifest {
        try HUDManifest.decode(Data(contentsOf: resources.appendingPathComponent(HUDManifest.fileName)))
    }

    func testManifestFollowsTheConventions() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.id, "xyz.machud.usagehud")
        XCTAssertEqual(manifest.socket, "usagehud", "socket name = CLI name = repo name")
        let panel = try XCTUnwrap(manifest.panel(id: ControlHost.panelID))
        XCTAssertEqual(panel.kind, .hover)
        XCTAssertTrue(panel.verbs.contains("frame"), "MacHUD places the panel with panel frame")
        let widget = try XCTUnwrap(manifest.panel(id: ControlHost.widgetType))
        XCTAssertEqual(widget.kind, .widget)
        XCTAssertEqual(manifest.dockPanels.map(\.id), [ControlHost.panelID])
    }

    @MainActor
    func testBuiltinManifestMirrorsTheFile() throws {
        XCTAssertEqual(ControlHost.builtinManifest, try manifest())
    }

    func testSettingsSchemaMatchesAppSettings() throws {
        let name = try XCTUnwrap(try manifest().panels.first?.settingsSchema)
        let data = try Data(contentsOf: resources.appendingPathComponent(name))
        let schema = try HUDSettingsSchema.decode(data)
        XCTAssertEqual(Set(schema.settings.map(\.key)), AppSettings.keys)
    }

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "xyz.machud.usagehud")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "UsageHUD")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertNotNil(plist["NSHumanReadableCopyright"])
    }
}
