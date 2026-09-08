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

/// The stuck-glucose detector exists because a Libre 3 field report showed the
/// current value pinned for the better part of an hour while Loop suspended
/// insulin on it. Its hard problem is the opposite direction: real glucose sits
/// flat at 1 mg/dL resolution often enough that a naive run-length trigger is
/// pure noise. These cover both sides.
final class StuckGlucoseDetectorTests: XCTestCase {
    private func frame(_ lifeCount: UInt16,
                       current: UInt16?,
                       historic: UInt16?,
                       lag: UInt16 = 15) -> StuckGlucoseDetector.Frame {
        StuckGlucoseDetector.Frame(lifeCount: lifeCount,
                                   currentWord: current ?? 0x8000,
                                   currentMgDL: current,
                                   historicMgDL: historic,
                                   historicLifeCount: lifeCount &- lag)
    }

    /// Feeds a run of identical values and returns every report produced.
    private func reports(_ frames: [StuckGlucoseDetector.Frame]) -> [StuckGlucoseDetector.Report] {
        var detector = StuckGlucoseDetector()
        return frames.compactMap { detector.observe($0) }
    }

    /// The longest genuinely-flat run in the 5-hour capture this was tuned
    /// against was 10 advancing frames, with the historic series tracking
    /// normally. Anything at or under that must stay silent.
    func testFlatGlucoseBelowThresholdIsSilent() {
        let frames = (0..<11).map { frame(1000 + UInt16($0), current: 165, historic: 157) }
        XCTAssertTrue(reports(frames).isEmpty)
    }

    /// A same-minute resend repeats the word without advancing lifeCount, and
    /// must not accumulate toward a run.
    func testSameMinuteResendsDoNotAccumulate() {
        let frames = (0..<40).map { _ in frame(1000, current: 165, historic: 157) }
        XCTAssertTrue(reports(frames).isEmpty)
    }

    /// Past the threshold it reports once, then only every fifth frame.
    func testLongHoldReportsOnceThenEveryFifthFrame() {
        let frames = (0..<28).map { frame(1000 + UInt16($0), current: 53, historic: 55) }
        let held: [StuckGlucoseDetector.Held] = reports(frames).compactMap {
            if case .held(let h) = $0 { return h }
            return nil
        }
        // Run indices 12, 17, 22, 27 → frame counts 13, 18, 23, 28.
        XCTAssertEqual(held.map(\.frames), [13, 18, 23, 28])
    }

    /// Dan's shape: the live value is pinned low and the sensor's own historic
    /// series carries the same low. The records agree, so this is not flagged as
    /// a latch — which is itself the finding, since it points at the sensor
    /// rather than at our decode of the realtime frame.
    func testHoldWithAgreeingHistoricIsNotMarkedDiverged() {
        let frames = (0..<28).map { frame(2000 + UInt16($0), current: 53, historic: 55) }
        let held: [StuckGlucoseDetector.Held] = reports(frames).compactMap {
            if case .held(let h) = $0 { return h }
            return nil
        }
        XCTAssertFalse(held.isEmpty)
        XCTAssertTrue(held.allSatisfy { !$0.diverged })
        XCTAssertEqual(held.last?.currentVsHistoric, 2)
    }

    /// A true latch: the live value sticks while the independently committed
    /// historic series keeps tracking real glucose down and away from it. Once
    /// the run outlasts the 15-minute historic lag, the disagreement is real.
    func testLatchDivergesOnceRunOutlastsHistoricLag() {
        let frames = (0..<32).map { i -> StuckGlucoseDetector.Frame in
            // Historic starts level with the pinned value, then falls 3/min.
            let historic = 120 - 3 * max(0, i - 12)
            return frame(3000 + UInt16(i), current: 120, historic: UInt16(max(40, historic)))
        }
        let held: [StuckGlucoseDetector.Held] = reports(frames).compactMap {
            if case .held(let h) = $0 { return h }
            return nil
        }
        XCTAssertFalse(held.first?.diverged ?? true, "not yet past the historic lag")
        XCTAssertTrue(held.last?.diverged ?? false, "records disagree well past the lag")
    }

    /// The move that ends a hold is diagnostic on its own: flat glucose resumes
    /// by a point or two, a released hold jumps.
    func testClearedReportCarriesTheStepThatBrokeTheRun() {
        var frames = (0..<20).map { frame(4000 + UInt16($0), current: 120, historic: 118) }
        frames.append(frame(4020, current: 96, historic: 118))
        guard case .cleared(let count, let step)? = reports(frames).last else {
            return XCTFail("expected a cleared report")
        }
        XCTAssertEqual(count, 20)
        XCTAssertEqual(step, -24)
    }

    /// A run of unavailable/error words is a different failure, already surfaced
    /// through the quality-assessment path and never forwarded to Loop.
    func testErrorWordsDoNotFormAStuckRun() {
        let frames = (0..<40).map { frame(5000 + UInt16($0), current: nil, historic: 118) }
        XCTAssertTrue(reports(frames).isEmpty)
    }
}
