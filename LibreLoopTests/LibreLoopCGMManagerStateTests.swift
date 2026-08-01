import XCTest
@testable import LibreLoop

final class LibreLoopCGMManagerStateTests: XCTestCase {
    func testRawValueRoundTrip() {
        var state = LibreLoopCGMManagerState()
        state.sensorSerial = "ABC123"
        state.activatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let raw = state.rawValue
        guard let restored = LibreLoopCGMManagerState(rawValue: raw) else {
            return XCTFail("Failed to restore state from rawValue")
        }

        XCTAssertEqual(restored.sensorSerial, state.sensorSerial)
        XCTAssertEqual(restored.activatedAt, state.activatedAt)
    }
}

final class LibreLoopSensorLifecycleTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func compute(activatedDaysAgo: Double,
                         needsReplacement: Bool,
                         endedNormally: Bool,
                         wearDurationMinutes: Int? = nil) -> LibreLoopSensorLifecycle {
        LibreLoopSensorLifecycle.compute(
            sensorPaired: true,
            activatedAt: now.addingTimeInterval(-activatedDaysAgo * day),
            latestReadingAt: nil,
            firstReadingAt: nil,
            lastPairedAt: nil,
            hasLiveMonitor: false,
            wearDurationMinutes: wearDurationMinutes,
            needsReplacement: needsReplacement,
            endedNormally: endedNormally,
            now: now
        )
    }

    // A clean end-of-life (`sensorEnded`) always shows Expired.
    func testEndedNormallyShowsExpired() {
        XCTAssertEqual(compute(activatedDaysAgo: 15, needsReplacement: true, endedNormally: true), .expired)
    }

    // The reported bug: a sensor past its rated wear reports the terminated
    // shutdown code (`replaceSensor`, endedNormally=false) — it must stay
    // Expired, not flip to "Sensor failed".
    func testReplaceSensorPastRatedWearShowsExpired() {
        XCTAssertEqual(compute(activatedDaysAgo: 15, needsReplacement: true, endedNormally: false), .expired)
    }

    // A genuine early failure (`replaceSensor` well before rated wear) stays Failed.
    func testReplaceSensorBeforeRatedWearShowsFailed() {
        XCTAssertEqual(compute(activatedDaysAgo: 3, needsReplacement: true, endedNormally: false), .failed)
    }

    // Honors a sensor-reported wear duration, not just the 14-day default.
    func testReplaceSensorPastReportedWearShowsExpired() {
        XCTAssertEqual(
            compute(activatedDaysAgo: 11, needsReplacement: true, endedNormally: false, wearDurationMinutes: 10 * 24 * 60),
            .expired
        )
    }
}
