import XCTest
import LoopKit
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
