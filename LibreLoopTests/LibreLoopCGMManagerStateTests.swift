import XCTest
import LoopKit
import RoundWhiteDiscKit
@testable import LibreLoop

final class LibreLoopCGMManagerStateTests: XCTestCase {
    func testRawValueRoundTrip() {
        var state = LibreLoopCGMManagerState()
        state.sensorSerial = "ABC123"
        state.activatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.generation = 1
        state.firmwareVersion = "1.1.31.0"

        let raw = state.rawValue
        guard let restored = LibreLoopCGMManagerState(rawValue: raw) else {
            return XCTFail("Failed to restore state from rawValue")
        }

        XCTAssertEqual(restored.sensorSerial, state.sensorSerial)
        XCTAssertEqual(restored.activatedAt, state.activatedAt)
        XCTAssertEqual(restored.generation, state.generation)
        XCTAssertEqual(restored.firmwareVersion, state.firmwareVersion)
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

/// `cgmManagerDelegate` is weak, so tests must hold this strongly.
private nonisolated final class RetractionRecordingDelegate: CGMManagerDelegate {
    private let lock = NSLock()
    private var _retracted: [Alert.Identifier] = []
    var retracted: [Alert.Identifier] {
        lock.lock()
        defer { lock.unlock() }
        return _retracted
    }

    private let retractionExpectation: XCTestExpectation
    private let deletionExpectation: XCTestExpectation?

    init(retractionExpectation: XCTestExpectation, deletionExpectation: XCTestExpectation? = nil) {
        self.retractionExpectation = retractionExpectation
        self.deletionExpectation = deletionExpectation
    }

    @MainActor func retractAlert(identifier: Alert.Identifier) async {
        lock.lock()
        _retracted.append(identifier)
        lock.unlock()
        retractionExpectation.fulfill()
    }

    func cgmManagerWantsDeletion(_ manager: CGMManager) async {
        deletionExpectation?.fulfill()
    }

    @MainActor func issueAlert(_ alert: Alert) async {}
    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {}
    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {}
    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {}
    func cgmManagerDidUpdateState(_ manager: CGMManager) {}
    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {}
    func startDateToFilterNewData(for manager: CGMManager) -> Date? { nil }
    func credentialStoragePrefix(for manager: CGMManager) -> String { "test" }
}

/// An alert left standing in Loop's AlertStore is replayed on every app launch,
/// so both exit paths must clear them.
final class LibreLoopAlertRetractionTests: XCTestCase {
    private func makeManager(delegate: CGMManagerDelegate) -> LibreLoopCGMManager {
        let manager = LibreLoopCGMManager()
        manager.delegateQueue = DispatchQueue(label: "LibreLoopAlertRetractionTests")
        manager.cgmManagerDelegate = delegate
        return manager
    }

    private func expectRetractions() -> XCTestExpectation {
        let expectation = expectation(description: "every alert identifier retracted")
        expectation.expectedFulfillmentCount = LibreLoopCGMManager.allAlertIdentifiers.count
        return expectation
    }

    private func assertRetractedEverything(_ delegate: RetractionRecordingDelegate) {
        XCTAssertEqual(Set(delegate.retracted.map(\.alertIdentifier)),
                       Set(LibreLoopCGMManager.allAlertIdentifiers))
        XCTAssertTrue(delegate.retracted.allSatisfy {
            $0.managerIdentifier == LibreLoopCGMManager.pluginIdentifier
        })
    }

    func testDeleteRetractsEveryAlertAndNotifiesDelegate() {
        let retractions = expectRetractions()
        let deletion = expectation(description: "delegate notified of deletion")
        let completed = expectation(description: "delete completion called")
        let delegate = RetractionRecordingDelegate(retractionExpectation: retractions,
                                                   deletionExpectation: deletion)
        let manager = makeManager(delegate: delegate)

        manager.delete { completed.fulfill() }

        wait(for: [retractions, deletion, completed], timeout: 5)
        assertRetractedEverything(delegate)
    }

    func testDiscardSensorRetractsEveryAlert() {
        let retractions = expectRetractions()
        let delegate = RetractionRecordingDelegate(retractionExpectation: retractions)
        let manager = makeManager(delegate: delegate)
        manager.hasIssuedReScanAlert = true

        manager.discardSensor()

        wait(for: [retractions], timeout: 5)
        assertRetractedEverything(delegate)
        XCTAssertFalse(manager.hasIssuedReScanAlert)
        XCTAssertNil(manager.lastSensorAttention)
    }

    func testAllAlertIdentifiersCoversEveryIssuableAlert() {
        let identifiers = Set(LibreLoopCGMManager.allAlertIdentifiers)
        for expiryIdentifier in LibreLoopExpiryAlerts.allIdentifiers {
            XCTAssertTrue(identifiers.contains(expiryIdentifier), "missing \(expiryIdentifier)")
        }
        XCTAssertTrue(identifiers.contains(LibreLoopCGMManager.sensorAttentionAlertID))
        XCTAssertTrue(identifiers.contains(LibreLoopCGMManager.needsReScanAlertID))
        XCTAssertEqual(identifiers.count, LibreLoopCGMManager.allAlertIdentifiers.count,
                       "duplicate identifiers in allAlertIdentifiers")
    }
}

final class LibreLoopSensorStateEventTests: XCTestCase {
    private func status(errorData: Int16 = 0, patchState: Int8 = 4) throws -> PatchStatus {
        var bytes = [UInt8](repeating: 0, count: PatchStatus.plaintextSize)
        bytes[2] = UInt8(truncatingIfNeeded: errorData)
        bytes[3] = UInt8(truncatingIfNeeded: errorData >> 8)
        bytes[7] = UInt8(bitPattern: patchState)
        return try PatchStatus(plaintext: Data(bytes))
    }

    private func manager() -> LibreLoopCGMManager {
        let manager = LibreLoopCGMManager()
        var state = LibreLoopCGMManagerState()
        state.sensorSerial = "0D00ABCDEF"
        state.activatedAt = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        manager.state = state
        return manager
    }

    func testIssueIsTheSensorErrorOrAttention() throws {
        XCTAssertNil(LibreLoopCGMManager.sensorIssue(for: try status()))
        XCTAssertEqual(LibreLoopCGMManager.sensorIssue(for: try status(errorData: 7)), "transmissionError")
        XCTAssertEqual(LibreLoopCGMManager.sensorIssue(for: try status(patchState: 3)), "checkSensor")
    }

    func testIssueIsTrackedUntilTheSensorIsHealthy() throws {
        let manager = manager()
        manager.handlePatchStatus(try status(errorData: 7))
        XCTAssertEqual(manager.state.reportedSensorIssue, "transmissionError")
        manager.handlePatchStatus(try status())
        XCTAssertNil(manager.state.reportedSensorIssue)
        XCTAssertFalse(manager.state.sensorEndRecorded)
    }

    func testReplacementRecordsTheSensorEndOnce() throws {
        let manager = manager()
        manager.handlePatchStatus(try status(errorData: 8, patchState: 6))
        XCTAssertEqual(manager.state.reportedSensorIssue, "terminated")
        XCTAssertTrue(manager.state.sensorEndRecorded)
        let restored = LibreLoopCGMManagerState(rawValue: manager.state.rawValue)
        XCTAssertEqual(restored?.reportedSensorIssue, "terminated")
        XCTAssertEqual(restored?.sensorEndRecorded, true)
    }

    func testAnErrorFromAnActiveSensorIsOnlyANotice() throws {
        let manager = manager()
        manager.handlePatchStatus(try status(errorData: 8))
        manager.handlePatchStatus(try status(errorData: 8))
        XCTAssertFalse(manager.state.sensorNeedsReplacement)
        XCTAssertFalse(manager.state.sensorEndRecorded)
        XCTAssertFalse(manager.isInoperable)
        XCTAssertEqual(manager.state.reportedSensorIssue, "terminated")
        XCTAssertEqual(manager.state.alertedSensorEvent, "checkSensor@0.0")
        XCTAssertEqual(LibreLoopCGMManagerState(rawValue: manager.state.rawValue)?.alertedSensorEvent, "checkSensor@0.0")

        manager.handlePatchStatus(try status())
        XCTAssertNil(manager.state.alertedSensorEvent)
        XCTAssertNil(manager.state.reportedSensorIssue)
    }

    func testTheSameErrorEndsTheSensorOnceItLeavesActive() throws {
        let manager = manager()
        manager.handlePatchStatus(try status(errorData: 8))
        manager.handlePatchStatus(try status(errorData: 8, patchState: 6))
        XCTAssertTrue(manager.state.sensorNeedsReplacement)
        XCTAssertTrue(manager.state.sensorEndRecorded)
    }

    func testDiscardingTheSensorClearsItsReplacement() throws {
        let manager = manager()
        manager.handlePatchStatus(try status(errorData: 8, patchState: 6))
        manager.discardSensor()
        XCTAssertFalse(manager.state.sensorNeedsReplacement)
        XCTAssertFalse(manager.state.sensorEndedNormally)
        XCTAssertNil(manager.state.alertedSensorEvent)
    }
}

final class LibreLoopRecentReadingsTests: XCTestCase {
    private let activatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ lifeCount: UInt16, _ mgdl: Double, source: LibreLoopGlucoseSample.Source = .realtime) -> LibreLoopGlucoseSample {
        LibreLoopGlucoseSample(
            date: activatedAt.addingTimeInterval(TimeInterval(lifeCount) * 60),
            valueMgDL: mgdl,
            trend: source == .realtime ? .stable : .notDetermined,
            rateOfChangeMgDLPerMinute: nil,
            lifeCount: lifeCount,
            sensorTemperatureRaw: 0,
            isActionable: true,
            source: source
        )
    }

    func testBackfillFillsTheGapInLifeCountOrder() {
        let manager = LibreLoopCGMManager()
        manager.recordSample(sample(100, 90))
        manager.recordSample(sample(130, 92))

        manager.recordBackfillSamples([sample(110, 93, source: .historicalBackfill), sample(100, 91, source: .historicalBackfill)])
        manager.recordBackfillSamples([sample(120, 94, source: .clinicalBackfill)])

        XCTAssertEqual(manager.recentSamples.map(\.lifeCount), [130, 120, 110, 100])
        XCTAssertEqual(manager.recentSamples.map(\.source), [.realtime, .clinicalBackfill, .historicalBackfill, .realtime])
        XCTAssertEqual(manager.latestSample?.lifeCount, 130)
    }

    func testRealtimeReplacesBackfillForTheSameMinute() {
        let manager = LibreLoopCGMManager()
        manager.recordBackfillSamples([sample(140, 95, source: .clinicalBackfill)])
        manager.recordSample(sample(140, 96))

        XCTAssertEqual(manager.recentSamples.map(\.lifeCount), [140])
        XCTAssertEqual(manager.recentSamples.first?.source, .realtime)
    }
}
