import Foundation
import XCTest
@testable import UsageHUDKit

final class BackoffTests: XCTestCase {
    func testDelayDoublesToTheCap() {
        XCTAssertEqual(Backoff.delay(level: 0), 120)
        XCTAssertEqual(Backoff.delay(level: 1), 240)
        XCTAssertEqual(Backoff.delay(level: 3), 960)
        XCTAssertEqual(Backoff.delay(level: 4), 1800, "capped at 30 minutes")
        XCTAssertEqual(Backoff.delay(level: 400), 1800)
    }

    func testRetryAfterWinsAndIsCapped() {
        XCTAssertEqual(Backoff.delay(level: 3, retryAfter: 30), 30)
        XCTAssertEqual(Backoff.delay(level: 0, retryAfter: 86400), 1800)
        XCTAssertEqual(Backoff.retryAfter("90", now: Fixtures.now), 90)
        XCTAssertEqual(Backoff.retryAfter("Tue, 13 Oct 2026 16:05:00 GMT", now: Fixtures.now), 300)
        XCTAssertNil(Backoff.retryAfter("Tue, 13 Oct 2026 15:00:00 GMT", now: Fixtures.now), "a date in the past")
        XCTAssertNil(Backoff.retryAfter("0", now: Fixtures.now))
        XCTAssertNil(Backoff.retryAfter("later", now: Fixtures.now))
        XCTAssertNil(Backoff.retryAfter(nil, now: Fixtures.now))
    }

    func testFailuresKeepTheReadingAndOnlyNetworkProblemsBackOff() {
        let reading = UsageReading(windows: [], observedAt: Fixtures.now.addingTimeInterval(-600))
        let good = ProviderRecord().succeeded(with: reading, at: Fixtures.now.addingTimeInterval(-600))
        let limited = good.failed(.rateLimited, at: Fixtures.now)
        XCTAssertEqual(limited.reading, reading, "the last good reading is kept")
        XCTAssertEqual(limited.backoffLevel, 1)
        XCTAssertEqual(limited.retryAt, Fixtures.now.addingTimeInterval(120))
        let again = limited.failed(.server(503), at: Fixtures.now, retryAfter: 45)
        XCTAssertEqual(again.backoffLevel, 2)
        XCTAssertEqual(again.retryAt, Fixtures.now.addingTimeInterval(45))
        let expired = again.failed(.expired, at: Fixtures.now)
        XCTAssertEqual(expired.backoffLevel, 0, "a local problem sent nothing, so it does not back off")
        XCTAssertNil(expired.retryAt)
        let recovered = again.succeeded(with: reading, at: Fixtures.now)
        XCTAssertEqual(recovered.backoffLevel, 0)
        XCTAssertNil(recovered.retryAt)
        XCTAssertNil(recovered.problem)
    }

    func testShouldWait() {
        let backingOff = ProviderRecord(lastAttemptAt: Fixtures.now.addingTimeInterval(-300), retryAt: Fixtures.now.addingTimeInterval(60))
        XCTAssertTrue(backingOff.shouldWait(at: Fixtures.now, minimumSpacing: 0))
        XCTAssertFalse(backingOff.shouldWait(at: Fixtures.now.addingTimeInterval(61), minimumSpacing: 30))
        let recent = ProviderRecord(lastAttemptAt: Fixtures.now.addingTimeInterval(-20))
        XCTAssertTrue(recent.shouldWait(at: Fixtures.now, minimumSpacing: 30))
        XCTAssertFalse(recent.shouldWait(at: Fixtures.now, minimumSpacing: 10))
        XCTAssertFalse(ProviderRecord().shouldWait(at: Fixtures.now, minimumSpacing: 60))
    }
}

final class StatusTests: XCTestCase {
    private let limit = UsageStatus.staleAfter(pollMinutes: 5)

    private func reading(age: TimeInterval, source: UsageReading.Source = .live) -> UsageReading {
        UsageReading(windows: [], observedAt: Fixtures.now.addingTimeInterval(-age), source: source)
    }

    func testStaleLimit() {
        XCTAssertEqual(limit, 660, "two 5-minute polls and a minute")
        XCTAssertEqual(UsageStatus.staleAfter(pollMinutes: 0), 180)
    }

    func testEveryState() {
        func status(_ record: ProviderRecord?, enabled: Bool = true) -> UsageStatus {
            UsageStatus.of(record, enabled: enabled, now: Fixtures.now, staleAfter: limit)
        }
        XCTAssertEqual(status(nil, enabled: false), .off)
        XCTAssertEqual(status(nil), .loading)
        XCTAssertEqual(status(ProviderRecord(problem: .expired)), .signedOut)
        XCTAssertEqual(status(ProviderRecord(problem: .keychainDenied)), .signedOut)
        XCTAssertEqual(status(ProviderRecord(problem: .rateLimited)), .error)
        XCTAssertEqual(status(ProviderRecord(reading: reading(age: 30))), .live)
        XCTAssertEqual(status(ProviderRecord(reading: reading(age: 700))), .stale(age: 700), "older than the limit")
        XCTAssertEqual(status(ProviderRecord(reading: reading(age: 30), problem: .expired)), .stale(age: 30),
                       "kept after a failed attempt")
        XCTAssertEqual(status(ProviderRecord(reading: reading(age: 30, source: .sessionLog), problem: .network("offline"))), .stale(age: 30))
    }

    func testHintsSpeakPlainly() {
        XCTAssertEqual(FetchProblem.expired.hint(for: .claude), "Open Claude Code to refresh your sign-in")
        XCTAssertEqual(FetchProblem.expired.hint(for: .codex), "Run codex to sign in")
        XCTAssertEqual(FetchProblem.signedOut.hint(for: .codex), "Run codex to sign in")
        XCTAssertEqual(FetchProblem.server(502).hint(for: .claude), "Claude answered 502")
    }
}

final class FormatTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(UsageFormat.duration(59), "<1m")
        XCTAssertEqual(UsageFormat.duration(7980), "2h 13m")
        XCTAssertEqual(UsageFormat.duration(3600), "1h")
        XCTAssertEqual(UsageFormat.duration(86400 * 3 + 3600 * 4 + 60 * 5), "3d 4h")
        XCTAssertEqual(UsageFormat.resets(Fixtures.now.addingTimeInterval(7980), now: Fixtures.now), "resets in 2h 13m")
        XCTAssertEqual(UsageFormat.resets(Fixtures.now.addingTimeInterval(-5), now: Fixtures.now), "resetting")
        XCTAssertNil(UsageFormat.resets(nil, now: Fixtures.now))
        XCTAssertEqual(UsageFormat.age(20), "just now")
        XCTAssertEqual(UsageFormat.age(3 * 3600 + 120), "3h 2m ago")
    }

    func testPercentCreditsPlan() {
        XCTAssertEqual(UsageFormat.percent(42.4), "42%")
        XCTAssertEqual(UsageFormat.percent(0.3), "<1%")
        XCTAssertEqual(UsageFormat.percent(0), "0%")
        XCTAssertEqual(UsageFormat.percent(nil), "—")
        XCTAssertEqual(UsageFormat.credits(62_500), "62,500")
        XCTAssertEqual(UsageFormat.credits(12.5), "12.5")
        XCTAssertEqual(UsageFormat.plan("max"), "Max")
        XCTAssertNil(UsageFormat.plan(" "))
    }
}
