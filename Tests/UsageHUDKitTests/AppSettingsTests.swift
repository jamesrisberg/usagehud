import Foundation
import XCTest
@testable import UsageHUDKit

final class AppSettingsTests: XCTestCase {
    func testApplyingParsesStrings() throws {
        let next = try AppSettings().applying(["pollMinutes": " 10 ", "claudeEnabled": "off", "codexEnabled": "yes"])
        XCTAssertEqual(next, AppSettings(pollMinutes: 10, claudeEnabled: false, codexEnabled: true))
        XCTAssertEqual(next.enabledProviders, [.codex])
    }

    func testApplyingRejectsBadValuesWithoutPartialChanges() {
        let settings = AppSettings()
        XCTAssertThrowsError(try settings.applying(["claudeEnabled": "maybe"])) {
            XCTAssertEqual($0 as? AppSettings.SettingsError, .invalid(key: "claudeEnabled", value: "maybe"))
        }
        XCTAssertThrowsError(try settings.applying(["pollMinutes": "0"]))
        XCTAssertThrowsError(try settings.applying(["pollMinutes": "61"]))
        XCTAssertThrowsError(try settings.applying(["pollMinutes": "five"]))
        XCTAssertThrowsError(try settings.applying(["colour": "red"])) {
            XCTAssertEqual($0 as? AppSettings.SettingsError, .unknownKey("colour"))
        }
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preferences.json")
        XCTAssertEqual(AppSettings.load(from: url), AppSettings(), "missing file reads as defaults")
        let custom = AppSettings(pollMinutes: 15, claudeEnabled: true, codexEnabled: false)
        try custom.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url), custom)
    }

    func testLoadMergesSavedValuesOverDefaultsKeyByKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preferences.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Written before codexEnabled existed, plus a key a later version dropped.
        try Data(#"{"pollMinutes": 7, "retired": 3}"#.utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings(pollMinutes: 7))
        // One value of the wrong type falls back alone; the rest are kept.
        try Data(#"{"pollMinutes": "often", "codexEnabled": false}"#.utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings(codexEnabled: false))
        // An interval out of range reads as the default.
        try Data(#"{"pollMinutes": 0}"#.utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings())
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(AppSettings.load(from: url), AppSettings())
    }

    func testJSONCoversEveryKey() {
        XCTAssertEqual(Set(AppSettings().json.keys), AppSettings.keys)
    }
}
