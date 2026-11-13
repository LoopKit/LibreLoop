import XCTest
import LoopKit
import RoundWhiteDiscKit
@testable import LibreLoop

/// Stands in for the NFC reader. The fake implements the fresh-only guard
/// itself, like Libre3NFCActivationReader (read the patch info, refuse
/// `.activateFreshSensor` on a sensor that isn't factory-fresh before sending
/// any command), so `commandsSent` only reflects the fake. The real guarantee
/// these tests check is `reader.modes == [.activateFreshSensor(...)]`: that
/// preActivate asks the reader for nothing else.
private final class FakeNFCReader: LibreLoopNFCScanning {
    let patchInfo: Libre3NFCPatchInfo
    let timeSeconds: UInt32
    private(set) var modes: [Libre3NFCScanMode] = []
    private(set) var commandsSent = 0

    init(patchInfo: Libre3NFCPatchInfo, timeSeconds: UInt32 = 1_700_000_000) {
        self.patchInfo = patchInfo
        self.timeSeconds = timeSeconds
    }

    func scan(mode: Libre3NFCScanMode) async throws -> Libre3NFCScanResult {
        modes.append(mode)
        guard case .activateFreshSensor(let receiverID, _) = mode else {
            XCTFail("unexpected mode \(mode)")
            throw Libre3NFCError.noTag
        }
        guard patchInfo.recommendedCommandCode == .activate else {
            throw Libre3NFCError.unexpectedSensorState(patchInfo: patchInfo)
        }
        commandsSent += 1
        let parameters = NFCActivationCommand.customRequestParameters(timeSeconds: timeSeconds, receiverID: receiverID)
        // 00 a5 00 | BLE address (LE) | PIN | activation time | CRC
        let response = Data([0x00, 0xa5, 0x00, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x01, 0x02, 0x03, 0x04, 0, 0, 0, 0, 0, 0])
        return Libre3NFCScanResult(
            patchInfo: patchInfo,
            commandCode: .activate,
            commandParameters: parameters,
            activationResponse: try Libre3NFCActivationResponse(raw: response)
        )
    }
}

/// `cgmManagerDelegate` is weak, so tests must hold this strongly.
private nonisolated final class AlertRecordingDelegate: CGMManagerDelegate {
    private let lock = NSLock()
    private var _issued: [Alert] = []
    private var _retracted: [Alert.Identifier] = []
    private var _events: [PersistedCgmEvent] = []
    var issued: [Alert] { lock.withLock { _issued } }
    var retracted: [Alert.Identifier] { lock.withLock { _retracted } }
    var events: [PersistedCgmEvent] { lock.withLock { _events } }
    let issueExpectation: XCTestExpectation?
    let retractExpectation: XCTestExpectation?

    init(issueExpectation: XCTestExpectation? = nil, retractExpectation: XCTestExpectation? = nil) {
        self.issueExpectation = issueExpectation
        self.retractExpectation = retractExpectation
    }

    @MainActor func issueAlert(_ alert: Alert) async {
        lock.withLock { _issued.append(alert) }
        issueExpectation?.fulfill()
    }
    @MainActor func retractAlert(identifier: Alert.Identifier) async {
        lock.withLock { _retracted.append(identifier) }
        retractExpectation?.fulfill()
    }
    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {}
    func startDateToFilterNewData(for manager: CGMManager) -> Date? { nil }
    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {}
    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) { lock.withLock { _events += events } }
    func cgmManagerWantsDeletion(_ manager: CGMManager) async {}
    func cgmManagerDidUpdateState(_ manager: CGMManager) {}
    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {}
    func credentialStoragePrefix(for manager: CGMManager) -> String { "test" }
}

/// Records the order the next sensor's alert calls arrive in; the first one
/// is held back a little, so a retraction that didn't wait would overtake it.
private nonisolated final class OrderRecordingDelegate: CGMManagerDelegate {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    @MainActor func issueAlert(_ alert: Alert) async {
        try? await Task.sleep(nanoseconds: 100_000_000)
        lock.withLock { _calls.append("issue") }
        expectation.fulfill()
    }
    @MainActor func retractAlert(identifier: Alert.Identifier) async {
        lock.withLock { _calls.append("retract") }
        expectation.fulfill()
    }
    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {}
    func startDateToFilterNewData(for manager: CGMManager) -> Date? { nil }
    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {}
    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {}
    func cgmManagerWantsDeletion(_ manager: CGMManager) async {}
    func cgmManagerDidUpdateState(_ manager: CGMManager) {}
    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {}
    func credentialStoragePrefix(for manager: CGMManager) -> String { "test" }
}

private extension Data {
    init?(nextSensorTestHex hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

final class LibreLoopNextSensorTests: XCTestCase {
    // Libre 3 Plus patch info; byte 17 is the patch state, 18..<27 the serial.
    private static let patchInfoHex = "00a50001000200010060541e020401040c0630545041304d514836fe98"
    private static let receiverID: UInt32 = 0x1234_5678

    private func patchInfo(state: UInt8, serial: String = "0TPA0MQH6") throws -> Libre3NFCPatchInfo {
        var bytes = [UInt8](try XCTUnwrap(Data(nextSensorTestHex: Self.patchInfoHex)))
        bytes[17] = state
        let serialBytes = [UInt8](serial.utf8)
        XCTAssertEqual(serialBytes.count, 9)
        bytes.replaceSubrange(18..<27, with: serialBytes)
        return try Libre3NFCPatchInfo(raw: Data(bytes))
    }

    private func pairedManager(serial: String = "CURRENT01") -> LibreLoopCGMManager {
        let manager = LibreLoopCGMManager()
        var state = LibreLoopCGMManagerState()
        state.sensorSerial = serial
        state.receiverID = Data([0x78, 0x56, 0x34, 0x12])
        state.bleAddress = "AA:BB:CC:DD:EE:FF"
        state.blePIN = Data([9, 9, 9, 9])
        state.peripheralID = UUID()
        state.activatedAt = Date(timeIntervalSince1970: 1_699_000_000)
        state.latestReadingTimestamp = Date(timeIntervalSince1970: 1_699_900_000)
        manager.state = state
        return manager
    }

    private func sampleNextSensor(serial: String = "NEXT00001") -> LibreLoopNextSensor {
        LibreLoopNextSensor(
            serial: serial,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            warmupDurationMinutes: 60,
            wearDurationMinutes: 15 * 24 * 60 + 12 * 60,
            generation: 1,
            firmwareVersion: "1.2.3.4",
            bleAddress: "11:22:33:44:55:66",
            receiverID: Self.receiverID
        )
    }

    // MARK: State

    func testStateRoundTripsTheNextSensor() throws {
        var state = LibreLoopCGMManagerState()
        state.sensorSerial = "CURRENT01"
        state.nextSensor = sampleNextSensor()
        state.previousSensorLastReadingAt = Date(timeIntervalSince1970: 1_699_999_000)

        let restored = try XCTUnwrap(LibreLoopCGMManagerState(rawValue: state.rawValue))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.nextSensor, sampleNextSensor())
        XCTAssertEqual(restored.sensorSerial, "CURRENT01")
    }

    func testStateRoundTripsWithoutANextSensor() throws {
        var state = LibreLoopCGMManagerState()
        state.sensorSerial = "CURRENT01"
        let raw = state.rawValue
        XCTAssertNil(raw["nextSensor"])
        XCTAssertNil(raw["previousSensorLastReadingAt"])
        let restored = try XCTUnwrap(LibreLoopCGMManagerState(rawValue: raw))
        XCTAssertNil(restored.nextSensor)
        XCTAssertNil(restored.previousSensorLastReadingAt)
        XCTAssertEqual(restored, state)
    }

    func testAnOlderRawStateWithoutTheKeysDecodes() throws {
        let raw: [String: Any] = [
            "sensorSerial": "CURRENT01",
            "activatedAt": Date(timeIntervalSince1970: 1_699_000_000),
            "wearDurationMinutes": 20_160,
        ]
        let restored = try XCTUnwrap(LibreLoopCGMManagerState(rawValue: raw))
        XCTAssertEqual(restored.sensorSerial, "CURRENT01")
        XCTAssertNil(restored.nextSensor)
        XCTAssertNil(restored.previousSensorLastReadingAt)
    }

    func testAMalformedNextSensorIsDroppedAndTheRestDecodes() throws {
        let raw: [String: Any] = [
            "sensorSerial": "CURRENT01",
            "nextSensor": ["activatedAt": Date()],      // no serial
        ]
        let restored = try XCTUnwrap(LibreLoopCGMManagerState(rawValue: raw))
        XCTAssertEqual(restored.sensorSerial, "CURRENT01")
        XCTAssertNil(restored.nextSensor)
        XCTAssertNil(LibreLoopCGMManagerState(rawValue: ["nextSensor": "garbage"])?.nextSensor)
    }

    // MARK: Ready time

    func testReadyTimeIsActivationPlusTheReportedWarmUp() {
        let next = sampleNextSensor()
        XCTAssertEqual(next.readyAt, next.activatedAt.addingTimeInterval(60 * 60))
        XCTAssertFalse(next.isReady(at: next.activatedAt.addingTimeInterval(59 * 60)))
        XCTAssertTrue(next.isReady(at: next.activatedAt.addingTimeInterval(60 * 60)))

        var longer = next
        longer.warmupDurationMinutes = 90
        XCTAssertEqual(longer.readyAt, next.activatedAt.addingTimeInterval(90 * 60))
    }

    func testReadyTimeFallsBackToTheDefaultWarmUp() {
        var next = sampleNextSensor()
        next.warmupDurationMinutes = nil
        XCTAssertEqual(next.readyAt, next.activatedAt.addingTimeInterval(LibreLoopSensorLifecycle.warmupDuration))
        next.warmupDurationMinutes = 0
        XCTAssertEqual(next.readyAt, next.activatedAt.addingTimeInterval(LibreLoopSensorLifecycle.warmupDuration))
    }

    func testRemainingLifeCountsFromActivation() {
        var next = sampleNextSensor()
        XCTAssertEqual(next.remainingLife(at: next.activatedAt.addingTimeInterval(24 * 60 * 60)), (14 * 24 + 12) * 60 * 60)
        XCTAssertEqual(next.remainingLife(at: next.activatedAt.addingTimeInterval(30 * 24 * 60 * 60)), 0)
        next.wearDurationMinutes = nil
        XCTAssertEqual(next.endsAt, next.activatedAt.addingTimeInterval(LibreLoopSensorLifecycle.activeDuration))
    }

    func testActivationTimeIsReadFromTheCommandParameters() {
        let parameters = NFCActivationCommand.customRequestParameters(timeSeconds: 1_700_000_123, receiverID: Self.receiverID)
        XCTAssertEqual(LibreLoopPairingService.activationTime(sentIn: parameters), Date(timeIntervalSince1970: 1_700_000_123))
        XCTAssertNil(LibreLoopPairingService.activationTime(sentIn: nil))
        XCTAssertNil(LibreLoopPairingService.activationTime(sentIn: Data([1, 2])))
    }

    // MARK: preActivate

    @MainActor
    func testAFreshSensorIsActivatedAndBecomesTheNextSensor() async throws {
        let manager = pairedManager()
        let issued = expectation(description: "ready alert issued")
        let delegate = AlertRecordingDelegate(issueExpectation: issued)
        manager.cgmManagerDelegate = delegate
        let before = manager.state
        let reader = FakeNFCReader(patchInfo: try patchInfo(state: 0x01, serial: "NEWSENSOR"), timeSeconds: UInt32(Date().timeIntervalSince1970) - 5)

        let result = try await manager.startNextSensorEarly { current, next in
            try await LibreLoopPairingService.preActivate(reader: reader, receiverID: Self.receiverID, currentSerial: current, nextSerial: next)
        }

        XCTAssertEqual(reader.modes, [.activateFreshSensor(receiverID: Self.receiverID)])
        XCTAssertEqual(reader.commandsSent, 1)
        guard case .activated(let next) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(next.serial, "NEWSENSOR")
        XCTAssertEqual(next.activatedAt, Date(timeIntervalSince1970: TimeInterval(reader.timeSeconds)))
        XCTAssertEqual(next.warmupDurationMinutes, 60)
        XCTAssertEqual(next.wearDurationMinutes, 21_600)
        XCTAssertEqual(next.generation, 1)
        XCTAssertEqual(next.bleAddress, "11:22:33:44:55:66")
        XCTAssertEqual(next.receiverID, Self.receiverID)
        XCTAssertEqual(manager.state.nextSensor, next)
        XCTAssertFalse(manager.canStartNextSensorEarly)

        // The current sensor is untouched.
        var expected = before
        expected.nextSensor = next
        XCTAssertEqual(manager.state, expected)

        // An alert at the ready time.
        await fulfillment(of: [issued], timeout: 5)
        let alert = try XCTUnwrap(delegate.issued.first { $0.identifier.alertIdentifier == LibreLoopCGMManager.nextSensorReadyAlertID })
        guard case .delayed(let interval) = alert.trigger else { return XCTFail("\(alert.trigger)") }
        XCTAssertEqual(interval, next.readyAt.timeIntervalSinceNow, accuracy: 5)
    }

    @MainActor
    func testScanningTheCurrentSensorSendsNothing() async throws {
        let manager = pairedManager(serial: "CURRENT01")
        let before = manager.state
        let reader = FakeNFCReader(patchInfo: try patchInfo(state: 0x04, serial: "CURRENT01"))

        let result = try await manager.startNextSensorEarly { current, next in
            try await LibreLoopPairingService.preActivate(reader: reader, receiverID: Self.receiverID, currentSerial: current, nextSerial: next)
        }

        XCTAssertEqual(result, .sensorInUse(serial: "CURRENT01"))
        XCTAssertEqual(reader.modes, [.activateFreshSensor(receiverID: Self.receiverID)])
        XCTAssertEqual(reader.commandsSent, 0)
        XCTAssertEqual(manager.state, before)
    }

    func testRescanningTheNextSensorSaysItIsAlreadyStarted() async throws {
        let reader = FakeNFCReader(patchInfo: try patchInfo(state: 0x02, serial: "NEXT00001"))
        let result = try await LibreLoopPairingService.preActivate(reader: reader, receiverID: Self.receiverID, currentSerial: "CURRENT01", nextSerial: "NEXT00001")
        XCTAssertEqual(result, .alreadyStarted(serial: "NEXT00001"))
        XCTAssertEqual(reader.commandsSent, 0)
    }

    func testAnotherSensorThatIsNotFreshIsNotStarted() async throws {
        func outcome(_ state: UInt8) async throws -> LibreLoopPairingService.PreActivationResult {
            let reader = FakeNFCReader(patchInfo: try patchInfo(state: state, serial: "OTHER0001"))
            let result = try await LibreLoopPairingService.preActivate(reader: reader, receiverID: Self.receiverID, currentSerial: "CURRENT01", nextSerial: nil)
            XCTAssertEqual(reader.commandsSent, 0)
            return result
        }
        let active = try await outcome(0x04)
        XCTAssertEqual(active, .alreadyActive(serial: "OTHER0001"))
        let warmingUp = try await outcome(0x02)
        XCTAssertEqual(warmingUp, .alreadyActive(serial: "OTHER0001"))
        let ended = try await outcome(0x06)
        XCTAssertEqual(ended, .sensorEnded(serial: "OTHER0001"))
        let insertionFailed = try await outcome(0x03)
        XCTAssertEqual(insertionFailed, .sensorInsertionFailed(serial: "OTHER0001"))
    }

    func testAnNFCErrorIsThrownAsThePairingFlowShowsIt() async throws {
        final class FailingReader: LibreLoopNFCScanning {
            func scan(mode: Libre3NFCScanMode) async throws -> Libre3NFCScanResult { throw Libre3NFCError.multipleTags }
        }
        do {
            _ = try await LibreLoopPairingService.preActivate(reader: FailingReader(), receiverID: Self.receiverID, currentSerial: "CURRENT01", nextSerial: nil)
            XCTFail("expected a failure")
        } catch let failure as LibreLoopPairingService.Failure {
            XCTAssertEqual(failure.description, "NFC scan failed: multipleTags")
        }
    }

    @MainActor
    func testNothingIsScannedWithoutAPairedSensorOrWithANextSensorWaiting() async throws {
        var scanned = false
        let unpaired = LibreLoopCGMManager()
        XCTAssertFalse(unpaired.canStartNextSensorEarly)
        do {
            _ = try await unpaired.startNextSensorEarly { _, _ in scanned = true; return .sensorInUse(serial: "") }
            XCTFail("expected a failure")
        } catch {}

        let waiting = pairedManager()
        waiting.state.nextSensor = sampleNextSensor()
        XCTAssertFalse(waiting.canStartNextSensorEarly)
        do {
            _ = try await waiting.startNextSensorEarly { _, _ in scanned = true; return .sensorInUse(serial: "") }
            XCTFail("expected a failure")
        } catch {}
        XCTAssertFalse(scanned)
    }

    // MARK: Switch

    func testAdoptingTheNextSensorClearsIt() {
        let manager = pairedManager()
        let retracted = expectation(description: "ready alert retracted")
        let delegate = AlertRecordingDelegate(retractExpectation: retracted)
        manager.cgmManagerDelegate = delegate
        manager.state.nextSensor = sampleNextSensor(serial: "NEXT00001")

        manager.clearNextSensorAfterAdopting(serial: "NEXT00001", switching: true)

        XCTAssertNil(manager.state.nextSensor)
        wait(for: [retracted], timeout: 5)
        XCTAssertTrue(delegate.retracted.contains { $0.alertIdentifier == LibreLoopCGMManager.nextSensorReadyAlertID })
    }

    func testAdoptingTheNextSensorThroughAnyPairingClearsIt() {
        let manager = pairedManager()
        manager.state.nextSensor = sampleNextSensor(serial: "NEXT00001")
        manager.clearNextSensorAfterAdopting(serial: "NEXT00001", switching: false)
        XCTAssertNil(manager.state.nextSensor)
    }

    func testSwitchingToAnotherConfirmedSensorClearsTheNextSensor() {
        let manager = pairedManager()
        manager.state.nextSensor = sampleNextSensor(serial: "NEXT00001")
        manager.clearNextSensorAfterAdopting(serial: "OTHER0001", switching: true)
        XCTAssertNil(manager.state.nextSensor)
    }

    func testAnOrdinaryReplaceWithAnotherSensorKeepsTheNextSensor() {
        let manager = pairedManager()
        manager.state.nextSensor = sampleNextSensor(serial: "NEXT00001")
        manager.clearNextSensorAfterAdopting(serial: "OTHER0001", switching: false)
        XCTAssertEqual(manager.state.nextSensor?.serial, "NEXT00001")
    }

    func testTheSwitchUsesTheReceiverIDTheNextSensorWasActivatedWith() {
        let next = sampleNextSensor()
        XCTAssertEqual(LibreLoopPairingService.switchMode(for: next, appReceiverID: Self.receiverID), .fresh)
        // A recovery pairing in between changed the app's ID.
        XCTAssertEqual(LibreLoopPairingService.switchMode(for: next, appReceiverID: 0x0BAD_F00D), .recovery(receiverID: Self.receiverID))
        var unknown = next
        unknown.receiverID = nil
        XCTAssertEqual(LibreLoopPairingService.switchMode(for: unknown, appReceiverID: 0x0BAD_F00D), .fresh)
    }

    private func nfcResponse(serial: String) -> LibreLoopPairingService.NFCResponse {
        LibreLoopPairingService.NFCResponse(
            receiverID: Self.receiverID,
            sensorSerial: serial,
            bleAddress: "11:22:33:44:55:66",
            blePIN: Data([1, 2, 3, 4]),
            activatedAt: nil,
            wearDurationMinutes: 21_600,
            warmupDurationMinutes: 60,
            generation: 1,
            firmwareVersion: "1.2.3.4"
        )
    }

    func testADeclinedSensorNeverReachesTheStateAndEmitsNoEvent() async throws {
        let manager = pairedManager()
        let delegate = AlertRecordingDelegate()
        manager.cgmManagerDelegate = delegate
        manager.state.nextSensor = sampleNextSensor(serial: "NEXT00001")
        manager.discardSensor()
        await manager.cgmDelegate.notify { _ in }.value
        let eventsBefore = delegate.events.count
        let before = manager.state

        do {
            try await LibreLoopPairingService.handOverNFCResponse(
                nfcResponse(serial: "OTHER0001"),
                continueAfterNFC: { _ in false },
                onNFCResponse: { manager.applyNFCResponse($0) }
            )
            XCTFail("expected the pairing to stop")
        } catch is CancellationError {}

        await manager.cgmDelegate.notify { _ in }.value
        XCTAssertEqual(manager.state, before)
        XCTAssertNil(manager.state.sensorSerial)
        XCTAssertNil(manager.state.blePIN)
        XCTAssertEqual(delegate.events.count, eventsBefore)
        XCTAssertEqual(manager.state.nextSensor?.serial, "NEXT00001")
    }

    func testAnAcceptedSensorIsSavedAfterTheAnswerAndBeforeAnythingElse() async throws {
        let manager = pairedManager()
        manager.discardSensor()
        var order: [String] = []
        try await LibreLoopPairingService.handOverNFCResponse(
            nfcResponse(serial: "OTHER0001"),
            continueAfterNFC: { _ in order.append("asked"); return true },
            onNFCResponse: { order.append("saved"); manager.applyNFCResponse($0) }
        )
        XCTAssertEqual(order, ["asked", "saved"])
        XCTAssertEqual(manager.state.sensorSerial, "OTHER0001")
        XCTAssertEqual(manager.state.blePIN, Data([1, 2, 3, 4]))
    }

    @MainActor
    func testTheReadyAlertIsRetractedAfterItIsIssued() async throws {
        let manager = pairedManager()
        let done = expectation(description: "issued, then retracted")
        done.expectedFulfillmentCount = 2
        let delegate = OrderRecordingDelegate(expectation: done)
        manager.cgmManagerDelegate = delegate
        let reader = FakeNFCReader(patchInfo: try patchInfo(state: 0x01, serial: "NEWSENSOR"), timeSeconds: UInt32(Date().timeIntervalSince1970))

        _ = try await manager.startNextSensorEarly { current, next in
            try await LibreLoopPairingService.preActivate(reader: reader, receiverID: Self.receiverID, currentSerial: current, nextSerial: next)
        }
        manager.forgetNextSensor()

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(delegate.calls, ["issue", "retract"])
    }

    func testDiscardingTheSensorKeepsTheNextSensorsReadyAlert() {
        let manager = pairedManager()
        let retractions = expectation(description: "the other alerts retracted")
        retractions.expectedFulfillmentCount = LibreLoopCGMManager.allAlertIdentifiers.count - 1
        let delegate = AlertRecordingDelegate(retractExpectation: retractions)
        manager.cgmManagerDelegate = delegate
        manager.state.nextSensor = sampleNextSensor()

        manager.discardSensor()

        wait(for: [retractions], timeout: 5)
        XCTAssertFalse(delegate.retracted.contains { $0.alertIdentifier == LibreLoopCGMManager.nextSensorReadyAlertID })
        XCTAssertTrue(delegate.retracted.contains { $0.alertIdentifier == LibreLoopCGMManager.sensorAttentionAlertID })
    }

    func testDiscardingTheSensorKeepsTheNextSensorAndSavesTheLastReadingTime() {
        let manager = pairedManager()
        let lastReading = manager.state.latestReadingTimestamp
        manager.state.nextSensor = sampleNextSensor()

        manager.discardSensor()

        XCTAssertNil(manager.state.sensorSerial)
        XCTAssertEqual(manager.state.nextSensor, sampleNextSensor())
        XCTAssertEqual(manager.state.previousSensorLastReadingAt, lastReading)

        // A second discard, with no reading in between, keeps it.
        manager.discardSensor()
        XCTAssertEqual(manager.state.previousSensorLastReadingAt, lastReading)
    }

    func testTheSwitchReceiverDatesTheNextSensorFromItsActivation() {
        let manager = pairedManager()
        let next = sampleNextSensor(serial: "NEXT00001")
        manager.state.nextSensor = next
        manager.discardSensor()

        manager.applyNFCResponse(LibreLoopPairingService.NFCResponse(
            receiverID: Self.receiverID,
            sensorSerial: "NEXT00001",
            bleAddress: "11:22:33:44:55:66",
            blePIN: Data([1, 2, 3, 4]),
            activatedAt: nil,
            wearDurationMinutes: 21_600,
            warmupDurationMinutes: 60,
            generation: 1,
            firmwareVersion: "1.2.3.4"
        ))

        XCTAssertEqual(manager.state.activatedAt, next.activatedAt)
    }

    func testForgettingTheNextSensorRetractsItsAlert() {
        let manager = pairedManager()
        let retracted = expectation(description: "ready alert retracted")
        let delegate = AlertRecordingDelegate(retractExpectation: retracted)
        manager.cgmManagerDelegate = delegate
        manager.state.nextSensor = sampleNextSensor()

        manager.forgetNextSensor()

        XCTAssertNil(manager.state.nextSensor)
        XCTAssertTrue(manager.canStartNextSensorEarly)
        wait(for: [retracted], timeout: 5)
        XCTAssertEqual(delegate.retracted.map(\.alertIdentifier), [LibreLoopCGMManager.nextSensorReadyAlertID])
    }

    // MARK: Reconnect filter

    func testReconnectWithoutAPeripheralIDTakesOnlyTheSavedBLEAddress() {
        let id = UUID()
        XCTAssertTrue(LibreLoopPairingService.reconnectAccepts(id: id, name: "AABBCCDDEEFF", expectedPeripheralID: nil, bleAddress: "AA:BB:CC:DD:EE:FF"))
        XCTAssertTrue(LibreLoopPairingService.reconnectAccepts(id: id, name: "aabbccddeeff", expectedPeripheralID: nil, bleAddress: "AA:BB:CC:DD:EE:FF"))
        // A next sensor warming up nearby, an unnamed peripheral, no saved address.
        XCTAssertFalse(LibreLoopPairingService.reconnectAccepts(id: id, name: "112233445566", expectedPeripheralID: nil, bleAddress: "AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(LibreLoopPairingService.reconnectAccepts(id: id, name: nil, expectedPeripheralID: nil, bleAddress: "AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(LibreLoopPairingService.reconnectAccepts(id: id, name: "AABBCCDDEEFF", expectedPeripheralID: nil, bleAddress: nil))
    }

    func testReconnectWithAPeripheralIDMatchesOnlyIt() {
        let saved = UUID()
        XCTAssertTrue(LibreLoopPairingService.reconnectAccepts(id: saved, name: nil, expectedPeripheralID: saved, bleAddress: nil))
        XCTAssertFalse(LibreLoopPairingService.reconnectAccepts(id: UUID(), name: "AABBCCDDEEFF", expectedPeripheralID: saved, bleAddress: "AA:BB:CC:DD:EE:FF"))
    }

    // MARK: Backfill clamp

    func testTheFirstBackfillAfterASwitchStartsAfterThePreviousSensorsLastReading() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        // Started early 10 h ago (lifeCount 600); the previous sensor read until 3 min ago.
        let from = LibreLoopCGMManager.backfillStartLifeCount(
            currentLifeCount: 600,
            readingAt: now,
            watermark: nil,
            previousSensorLastReadingAt: now.addingTimeInterval(-3 * 60)
        )
        XCTAssertEqual(from, 598)
    }

    func testTheClampDoesNotWidenTheRequest() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        // Without the clamp: 180 lifeCounts back. A previous reading long before that changes nothing.
        XCTAssertEqual(LibreLoopCGMManager.backfillStartLifeCount(currentLifeCount: 600, readingAt: now, watermark: nil, previousSensorLastReadingAt: nil), 420)
        XCTAssertEqual(LibreLoopCGMManager.backfillStartLifeCount(currentLifeCount: 600, readingAt: now, watermark: nil, previousSensorLastReadingAt: now.addingTimeInterval(-24 * 60 * 60)), 420)
        // A watermark keeps its overlap unless that reaches back over the previous sensor.
        XCTAssertEqual(LibreLoopCGMManager.backfillStartLifeCount(currentLifeCount: 600, readingAt: now, watermark: 590, previousSensorLastReadingAt: nil), 580)
        XCTAssertEqual(LibreLoopCGMManager.backfillStartLifeCount(currentLifeCount: 600, readingAt: now, watermark: 590, previousSensorLastReadingAt: now.addingTimeInterval(-5 * 60)), 596)
        // Never past the current reading, even with a clock that went backwards.
        XCTAssertEqual(LibreLoopCGMManager.backfillStartLifeCount(currentLifeCount: 600, readingAt: now, watermark: nil, previousSensorLastReadingAt: now.addingTimeInterval(60 * 60)), 600)
    }

    private func reading(at date: Date, lifeCount: UInt16) -> LibreLoopGlucoseSample {
        LibreLoopGlucoseSample(
            date: date,
            valueMgDL: 110,
            trend: .stable,
            rateOfChangeMgDLPerMinute: nil,
            lifeCount: lifeCount,
            sensorTemperatureRaw: 0,
            isActionable: true,
            source: .realtime
        )
    }

    func testTheCutoffIsKeptOnlyWhileBackfillCouldReachIt() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(LibreLoopCGMManager.keepsPreviousSensorCutoff(cutoff, readingAt: cutoff.addingTimeInterval(60)))
        XCTAssertTrue(LibreLoopCGMManager.keepsPreviousSensorCutoff(cutoff, readingAt: cutoff.addingTimeInterval(6 * 60 * 60)))
        XCTAssertFalse(LibreLoopCGMManager.keepsPreviousSensorCutoff(cutoff, readingAt: cutoff.addingTimeInterval(6 * 60 * 60 + 60)))
        // The phone clock stepped backwards.
        XCTAssertFalse(LibreLoopCGMManager.keepsPreviousSensorCutoff(cutoff, readingAt: cutoff))
        XCTAssertFalse(LibreLoopCGMManager.keepsPreviousSensorCutoff(cutoff, readingAt: cutoff.addingTimeInterval(-60)))
    }

    func testARealtimeReadingClearsTheCutoffOncePastIt() {
        let manager = pairedManager()
        let cutoff = Date().addingTimeInterval(-7 * 60 * 60)
        manager.state.previousSensorLastReadingAt = cutoff
        manager.state.activatedAt = cutoff.addingTimeInterval(-60 * 60)

        manager.ingest(reading(at: cutoff.addingTimeInterval(60 * 60), lifeCount: 120))
        XCTAssertEqual(manager.state.previousSensorLastReadingAt, cutoff)

        manager.ingest(reading(at: cutoff.addingTimeInterval(7 * 60 * 60), lifeCount: 480))
        XCTAssertNil(manager.state.previousSensorLastReadingAt)
    }

    func testBackfillDatedBeforeThePreviousSensorsLastReadingIsDropped() {
        let manager = LibreLoopCGMManager()
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(manager.isBackfillOverlappingPreviousSensor(last))
        manager.state.previousSensorLastReadingAt = last
        XCTAssertTrue(manager.isBackfillOverlappingPreviousSensor(last))
        XCTAssertTrue(manager.isBackfillOverlappingPreviousSensor(last.addingTimeInterval(-60)))
        XCTAssertFalse(manager.isBackfillOverlappingPreviousSensor(last.addingTimeInterval(60)))
    }
}
