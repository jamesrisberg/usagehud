import Foundation
import XCTest
@testable import UsageHUDKit

final class ClaudeNormalizerTests: XCTestCase {
    private func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }

    func testNamedWindowsAndTheScopedModelCap() throws {
        let windows = try XCTUnwrap(ClaudeUsage.windows(from: try json(Fixtures.claudeUsage)))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "seven_day_model", "seven_day_cowork"],
                       "null windows are skipped, and limits[] supersedes iguana_necktie")
        let session = windows[0]
        XCTAssertEqual(session.label, "Session")
        XCTAssertEqual(session.kind, .session)
        XCTAssertEqual(session.percentUsed, 42)
        XCTAssertEqual(session.windowSeconds, 18000)
        let reset = try XCTUnwrap(session.resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, Fixtures.now.timeIntervalSince1970 + 2 * 3600 + 13 * 60 + 0.493577, accuracy: 0.001,
                       "six fractional digits parse")
        let model = try XCTUnwrap(windows.first { $0.id == "seven_day_model" })
        XCTAssertEqual(model.label, "Fable 5 weekly", "the provider's own display name")
        XCTAssertEqual(model.percentUsed, 61, "the limits[] percent, not iguana_necktie's 58")
        XCTAssertEqual(model.kind, .model)
        XCTAssertEqual(windows.first { $0.id == "seven_day_opus" }?.resetsAt, nil, "a null reset stays nil")
    }

    func testWithoutLimitsTheRawModelKeyIsTheModelRowAndValuesClamp() throws {
        let windows = try XCTUnwrap(ClaudeUsage.windows(from: try json(Fixtures.claudeUsageWithoutLimits)))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_model"])
        XCTAssertEqual(windows[0].percentUsed, 100, "clamped to 100")
        XCTAssertEqual(windows[1].percentUsed, 0, "clamped to 0")
        XCTAssertEqual(windows[0].resetsAt?.timeIntervalSince1970, 1_791_915_180, "unix seconds")
        XCTAssertEqual(windows[1].resetsAt?.timeIntervalSince1970, 1_792_119_600, "unix milliseconds")
        XCTAssertEqual(windows[2].label, "Fable weekly")
        XCTAssertEqual(windows[2].percentUsed, 90)
    }

    func testAnInactiveScopedLimitIsUsedWhenNoneIsActive() throws {
        let payload = try json(#"{"seven_day": {"utilization": 5, "resets_at": null}, "limits": [{"kind": "weekly_scoped", "percent": 12, "is_active": false, "scope": {}}]}"#)
        let windows = try XCTUnwrap(ClaudeUsage.windows(from: payload))
        XCTAssertEqual(windows.last?.label, "Top model weekly")
        XCTAssertEqual(windows.last?.percentUsed, 12)
    }

    func testUnreadablePayloads() throws {
        XCTAssertNil(ClaudeUsage.windows(from: nil))
        XCTAssertNil(ClaudeUsage.windows(from: try json("[]")))
        XCTAssertNil(ClaudeUsage.windows(from: try json(#"{"error": {"type": "rate_limit_error"}}"#)))
        XCTAssertNil(ClaudeUsage.reading(from: Data("<html>".utf8), plan: nil, at: Fixtures.now))
    }

    func testReadingCarriesThePlan() throws {
        let reading = try XCTUnwrap(ClaudeUsage.reading(from: Data(Fixtures.claudeUsage.utf8), plan: "max", at: Fixtures.now))
        XCTAssertEqual(reading.plan, "max")
        XCTAssertEqual(reading.source, .live)
        XCTAssertEqual(reading.observedAt, Fixtures.now)
    }
}

final class CodexNormalizerTests: XCTestCase {
    func testTheRealPayload() throws {
        let reading = try XCTUnwrap(CodexUsage.reading(from: Data(Fixtures.codexUsage.utf8), at: Fixtures.now))
        XCTAssertEqual(reading.plan, "pro")
        XCTAssertEqual(reading.windows.count, 1)
        let weekly = reading.windows[0]
        XCTAssertEqual(weekly.id, "seven_day", "classified by its length although it is the primary window")
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.percentUsed, 0)
        XCTAssertEqual(weekly.resetsAt?.timeIntervalSince1970, 1_792_511_708, "reset_at wins over reset_after_seconds")
        XCTAssertEqual(reading.credits, Credits(hasCredits: true, unlimited: false, balance: 62_500))
    }

    func testTwoWindowsSortShortestFirstAndResetAfterResolvesAgainstNow() throws {
        let reading = try XCTUnwrap(CodexUsage.reading(from: Data(Fixtures.codexUsageTwoWindows.utf8), at: Fixtures.now))
        XCTAssertEqual(reading.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(reading.windows[0].percentUsed, 62.2)
        XCTAssertEqual(reading.windows[0].resetsAt, Fixtures.now.addingTimeInterval(4080))
        XCTAssertEqual(reading.windows[1].resetsAt, PayloadValues.iso8601("2026-10-17T09:00:00Z"))
        XCTAssertNil(reading.credits)
    }

    func testLimitReachedWithoutAPercentReadsAsFull() throws {
        let payload = try JSONSerialization.jsonObject(with: Data(#"{"rate_limit": {"limit_reached": true, "primary_window": {"limit_window_seconds": 18000, "reset_after_seconds": 600}}}"#.utf8))
        XCTAssertEqual(CodexUsage.windows(from: payload, now: Fixtures.now)?.first?.percentUsed, 100)
    }

    func testMonthlyAndDuplicateWindows() throws {
        let monthly = try JSONSerialization.jsonObject(with: Data(#"{"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000}, "secondary_window": {"used_percent": 2, "limit_window_seconds": 2592000}}}"#.utf8))
        XCTAssertEqual(CodexUsage.windows(from: monthly, now: Fixtures.now)?.map(\.id), ["five_hour", "monthly"])
        let twice = try JSONSerialization.jsonObject(with: Data(#"{"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000}, "secondary_window": {"used_percent": 2, "limit_window_seconds": 18000}}}"#.utf8))
        XCTAssertEqual(CodexUsage.windows(from: twice, now: Fixtures.now)?.count, 1)
    }

    func testUnreadablePayloads() {
        XCTAssertNil(CodexUsage.reading(from: Data(#"{"detail": "Unauthorized"}"#.utf8), at: Fixtures.now))
        XCTAssertNil(CodexUsage.reading(from: Data("nope".utf8), at: Fixtures.now))
        XCTAssertNotNil(CodexUsage.reading(from: Data(#"{"rate_limit": null, "credits": {"has_credits": false, "unlimited": true}}"#.utf8), at: Fixtures.now),
                        "credits alone are a reading")
    }
}

final class SessionLogTests: XCTestCase {
    func testTheNewestRecordWithRateLimitsWins() throws {
        let reading = try XCTUnwrap(CodexSessionLog.latestReading(inLines: Data(Fixtures.sessionLog.utf8)))
        XCTAssertEqual(reading.source, .sessionLog)
        XCTAssertEqual(reading.observedAt, PayloadValues.iso8601("2026-10-13T15:58:42.070Z"), "a null rate_limits after it is skipped")
        XCTAssertEqual(reading.windows.map(\.id), ["five_hour", "seven_day"], "window_minutes 300 and 10080")
        XCTAssertEqual(reading.windows[0].percentUsed, 71)
        XCTAssertEqual(reading.windows[1].percentUsed, 4.5)
        XCTAssertEqual(reading.windows[1].resetsAt?.timeIntervalSince1970, 1_792_511_708)
        XCTAssertEqual(reading.credits?.balance, 62_500)
        XCTAssertEqual(reading.plan, "pro")
    }

    func testAPartialFirstLineIsDropped() {
        let line = Fixtures.sessionRecord(timestamp: "2026-10-13T15:10:00.000Z", usedPercent: 3)
        let cut = Data(line.utf8).suffix(from: 40)
        XCTAssertNil(CodexSessionLog.latestReading(inLines: Data(cut), partialFirstLine: true))
        XCTAssertNotNil(CodexSessionLog.latestReading(inLines: Data((line + "\n").utf8), partialFirstLine: false))
    }

    func testRecordWithoutWindowsOrTimestamp() throws {
        let noTime = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"payload": {"rate_limits": {"primary": {"used_percent": 1, "window_minutes": 300}}}}"#.utf8)) as? [String: Any])
        XCTAssertNil(CodexSessionLog.reading(fromRecord: noTime))
        let empty = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"timestamp": "2026-10-13T15:10:00Z", "payload": {"rate_limits": {"primary": null, "secondary": null}}}"#.utf8)) as? [String: Any])
        XCTAssertNil(CodexSessionLog.reading(fromRecord: empty))
    }

    func testFindsTheNewestFilesInTheDateTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ lines: [String], modified: Date) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try write("2026/09/30/rollout-old.jsonl", [Fixtures.sessionRecord(timestamp: "2026-09-30T10:00:00Z", usedPercent: 80)],
                  modified: Fixtures.now.addingTimeInterval(-86400 * 13))
        try write("2026/10/13/rollout-a.jsonl", [Fixtures.sessionRecord(timestamp: "2026-10-13T09:00:00Z", usedPercent: 10)],
                  modified: Fixtures.now.addingTimeInterval(-7 * 3600))
        try write("2026/10/13/rollout-b.jsonl", [Fixtures.sessionRecord(timestamp: "2026-10-13T15:00:00Z", usedPercent: 20),
                                                  #"{"timestamp":"2026-10-13T15:01:00Z","type":"event_msg","payload":{"rate_limits":null}}"#],
                  modified: Fixtures.now.addingTimeInterval(-3600))
        try write("2026/10/13/notes.txt", ["ignored"], modified: Fixtures.now)

        var log = CodexSessionLog(sessionsDirectory: root)
        log.fileLimit = 2
        XCTAssertEqual(log.newestFiles().map(\.lastPathComponent), ["rollout-b.jsonl", "rollout-a.jsonl"])
        XCTAssertEqual(log.latestReading()?.windows.first?.percentUsed, 20)
        XCTAssertNil(CodexSessionLog(sessionsDirectory: root.appendingPathComponent("missing")).latestReading())
    }

    func testAChunkedBackwardScanFindsARecordFarFromTheEndAndAcrossChunks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filler = String(repeating: #"{"type":"response_item","payload":{"text":"xxxxxxxxxxxxxxxx"}}"# + "\n", count: 200)
        let url = dir.appendingPathComponent("rollout.jsonl")
        try Data((Fixtures.sessionRecord(timestamp: "2026-10-13T15:00:00Z", usedPercent: 33) + "\n" + filler).utf8).write(to: url)
        for chunk in [64, 100, 1024, 1 << 20] {
            var log = CodexSessionLog(sessionsDirectory: dir)
            log.chunkBytes = chunk
            XCTAssertEqual(log.latestReading(in: url)?.windows.first?.percentUsed, 33, "chunks of \(chunk) bytes")
        }
        // The newest of several records wins, whatever the chunk boundaries.
        try Data((Fixtures.sessionRecord(timestamp: "2026-10-13T15:00:00Z", usedPercent: 33) + "\n" + filler
                  + Fixtures.sessionRecord(timestamp: "2026-10-13T15:30:00Z", usedPercent: 44) + "\n" + filler).utf8).write(to: url)
        var log = CodexSessionLog(sessionsDirectory: dir)
        log.chunkBytes = 300
        XCTAssertEqual(log.latestReading(in: url)?.windows.first?.percentUsed, 44)
    }

    func testAnUnchangedFileIsNotReadTwice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-memo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout.jsonl")
        try Data((Fixtures.sessionRecord(timestamp: "2026-10-13T15:00:00Z", usedPercent: 33) + "\n").utf8).write(to: url)
        let log = CodexSessionLog(sessionsDirectory: dir)
        XCTAssertEqual(log.latestReading()?.windows.first?.percentUsed, 33)
        XCTAssertEqual(log.latestReading()?.windows.first?.percentUsed, 33)
        XCTAssertEqual(log.memo.scanCount, 1, "the second look is remembered")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Fixtures.sessionRecord(timestamp: "2026-10-13T15:10:00Z", usedPercent: 35) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(log.latestReading()?.windows.first?.percentUsed, 35, "a file that grew is read again")
        XCTAssertEqual(log.memo.scanCount, 2)
    }

    func testFilesArePickedByModificationDateNotByFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-mtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ line: String, modified: Date) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((line + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        // A long session started on the 9th and still being written, and newer folders with older sessions.
        try write("2026/10/09/rollout-long.jsonl", Fixtures.sessionRecord(timestamp: "2026-10-13T15:55:00Z", usedPercent: 61),
                  modified: Fixtures.now.addingTimeInterval(-300))
        for day in 10...13 {
            try write("2026/10/\(day)/rollout-\(day).jsonl", Fixtures.sessionRecord(timestamp: "2026-10-\(day)T08:00:00Z", usedPercent: Double(day)),
                      modified: Fixtures.now.addingTimeInterval(-Double(14 - day) * 86400))
        }
        var log = CodexSessionLog(sessionsDirectory: root)
        log.fileLimit = 2
        XCTAssertEqual(log.newestFiles().map(\.lastPathComponent), ["rollout-long.jsonl", "rollout-13.jsonl"])
        XCTAssertEqual(log.latestReading()?.windows.first?.percentUsed, 61)
    }

    func testOlderLogsResetInSecondsFromTheRecord() throws {
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"timestamp": "2026-10-13T15:00:00Z", "payload": {"rate_limits": {"primary": {"used_percent": 12, "window_minutes": 300, "resets_in_seconds": 1800}}}}"#.utf8)) as? [String: Any])
        let reading = try XCTUnwrap(CodexSessionLog.reading(fromRecord: record))
        XCTAssertEqual(reading.windows.first?.resetsAt, PayloadValues.iso8601("2026-10-13T15:30:00Z"))
    }
}

final class PayloadValueTests: XCTestCase {
    func testDates() {
        XCTAssertEqual(PayloadValues.date("2026-10-13T16:00:00Z"), Fixtures.now)
        XCTAssertEqual(PayloadValues.date("2026-10-13T16:00:00.5Z")?.timeIntervalSince1970 ?? 0, Fixtures.now.timeIntervalSince1970 + 0.5, accuracy: 0.0001)
        XCTAssertEqual(PayloadValues.date("2026-10-13T18:00:00+02:00"), Fixtures.now)
        XCTAssertEqual(PayloadValues.date(1_791_907_200), Fixtures.now)
        XCTAssertEqual(PayloadValues.date("1791907200"), Fixtures.now)
        XCTAssertEqual(PayloadValues.date(1_791_907_200_000), Fixtures.now)
        XCTAssertNil(PayloadValues.date(0))
        XCTAssertNil(PayloadValues.date("soon"))
        XCTAssertNil(PayloadValues.date(nil))
        XCTAssertNil(PayloadValues.date(true))
    }

    func testNumbersAndBools() throws {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(#"{"t": true, "one": 1, "s": "2.5"}"#.utf8)) as? [String: Any])
        XCTAssertNil(PayloadValues.number(json["t"]), "a JSON bool is not a number")
        XCTAssertEqual(PayloadValues.number(json["one"]), 1)
        XCTAssertEqual(PayloadValues.number(json["s"]), 2.5)
        XCTAssertEqual(PayloadValues.bool(json["t"]), true)
        XCTAssertNil(PayloadValues.bool(json["one"]), "a JSON 1 is not a bool")
    }
}

final class MeterWindowTests: XCTestCase {
    func testAWindowPastItsResetNoLongerHoldsItsNumber() {
        let window = UsageWindow(id: "five_hour", label: "Session", kind: .session, percentUsed: 80,
                                 resetsAt: Fixtures.now.addingTimeInterval(-1), windowSeconds: 18000)
        XCTAssertTrue(window.hasReset(at: Fixtures.now))
        XCTAssertNil(window.currentPercent(at: Fixtures.now))
        XCTAssertEqual(window.currentPercent(at: Fixtures.now.addingTimeInterval(-60)), 80)
        XCTAssertEqual(UsageFormat.resets(window.resetsAt, now: Fixtures.now), "reset, waiting for a new reading")
        var noReset = window
        noReset.resetsAt = nil
        XCTAssertEqual(noReset.currentPercent(at: Fixtures.now), 80)
    }

    func testUnusedExtrasAndOtherModelsHaveNoMeter() throws {
        let reading = try XCTUnwrap(ClaudeUsage.reading(from: Data(Fixtures.claudeUsage.utf8), plan: nil, at: Fixtures.now))
        XCTAssertEqual(reading.meterWindows.map(\.id), ["five_hour", "seven_day", "seven_day_model"],
                       "Opus and Cowork at 0% stay out; the top model's cap stays in")
        var used = reading
        used.windows[2].percentUsed = 4
        XCTAssertEqual(used.meterWindows.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "seven_day_model"])
    }
}
