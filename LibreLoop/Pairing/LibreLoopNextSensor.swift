import Foundation
import LoopKit
import RoundWhiteDiscKit

/// A sensor started early: activated over NFC (`0xA0`) while the current
/// sensor keeps working, so its warm-up and wear time run now. Switching to it
/// later is the ordinary replace flow (`0xA8` switch-receiver, then BLE
/// pairing). Holds only what identifies it and dates it; no PIN or keys.
public struct LibreLoopNextSensor: RawRepresentable, Equatable, Sendable {
    public typealias RawValue = [String: Any]

    public var serial: String
    /// The phone time sent in the activation command.
    public var activatedAt: Date
    public var warmupDurationMinutes: Int?
    public var wearDurationMinutes: Int?
    public var generation: UInt16?
    public var firmwareVersion: String?
    /// Identity only: what the sensor advertises over BLE.
    public var bleAddress: String?
    /// The receiver ID the activation was sent with; the sensor only accepts
    /// a switch-receiver from it.
    public var receiverID: UInt32?

    public init(
        serial: String,
        activatedAt: Date,
        warmupDurationMinutes: Int? = nil,
        wearDurationMinutes: Int? = nil,
        generation: UInt16? = nil,
        firmwareVersion: String? = nil,
        bleAddress: String? = nil,
        receiverID: UInt32? = nil
    ) {
        self.serial = serial
        self.activatedAt = activatedAt
        self.warmupDurationMinutes = warmupDurationMinutes
        self.wearDurationMinutes = wearDurationMinutes
        self.generation = generation
        self.firmwareVersion = firmwareVersion
        self.bleAddress = bleAddress
        self.receiverID = receiverID
    }

    public init?(rawValue: RawValue) {
        guard let serial = rawValue["serial"] as? String,
              let activatedAt = rawValue["activatedAt"] as? Date else { return nil }
        self.serial = serial
        self.activatedAt = activatedAt
        self.warmupDurationMinutes = rawValue["warmupDurationMinutes"] as? Int
        self.wearDurationMinutes = rawValue["wearDurationMinutes"] as? Int
        self.generation = (rawValue["generation"] as? Int).map { UInt16(clamping: $0) }
        self.firmwareVersion = rawValue["firmwareVersion"] as? String
        self.bleAddress = rawValue["bleAddress"] as? String
        self.receiverID = (rawValue["receiverID"] as? Int).map { UInt32(clamping: $0) }
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "serial": serial,
            "activatedAt": activatedAt,
        ]
        raw["warmupDurationMinutes"] = warmupDurationMinutes
        raw["wearDurationMinutes"] = wearDurationMinutes
        raw["generation"] = generation.map { Int($0) }
        raw["firmwareVersion"] = firmwareVersion
        raw["bleAddress"] = bleAddress
        raw["receiverID"] = receiverID.map { Int($0) }
        return raw
    }

    /// End of the sensor-reported warm-up, or the 60-minute default.
    public var readyAt: Date {
        let minutes = warmupDurationMinutes.flatMap { $0 > 0 ? $0 : nil }
        return activatedAt.addingTimeInterval(minutes.map { TimeInterval($0) * 60 } ?? LibreLoopSensorLifecycle.warmupDuration)
    }

    /// End of the sensor-reported wear time, or the 14-day default.
    public var endsAt: Date {
        let minutes = wearDurationMinutes.flatMap { $0 > 0 ? $0 : nil }
        return activatedAt.addingTimeInterval(minutes.map { TimeInterval($0) * 60 } ?? LibreLoopSensorLifecycle.activeDuration)
    }

    public func isReady(at now: Date = Date()) -> Bool {
        now >= readyAt
    }

    public func remainingLife(at now: Date = Date()) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(now))
    }

    public var sensorModel: String? {
        generation.map { $0 == 0 ? "Libre 3" : "Libre 3 Plus" }
    }
}

/// The NFC reader `preActivate` talks to; a protocol so tests can stand in.
protocol LibreLoopNFCScanning {
    func scan(mode: Libre3NFCScanMode) async throws -> Libre3NFCScanResult
}

#if targetEnvironment(simulator)
extension LibreLoopSimulatedNFCReader: LibreLoopNFCScanning {}
#else
extension Libre3NFCActivationReader: LibreLoopNFCScanning {}
#endif

extension LibreLoopPairingService {
    public enum PreActivationResult: Equatable, Sendable {
        /// A factory-fresh sensor was activated; it is the next sensor now.
        case activated(LibreLoopNextSensor)
        /// The scanned sensor is the next sensor, already started.
        case alreadyStarted(serial: String)
        /// The scanned sensor is the one in use.
        case sensorInUse(serial: String)
        /// The scanned sensor is active, but neither the current nor the next one.
        case alreadyActive(serial: String)
        case sensorEnded(serial: String)
        case sensorInsertionFailed(serial: String)
    }

    /// Starts the next sensor's warm-up and wear time without touching the
    /// current sensor: NFC only, and only a factory-fresh sensor is activated.
    /// The reader reads the patch info first and sends nothing to a sensor
    /// that is already active, so scanning the current sensor by mistake can't
    /// switch its receiver.
    public func preActivate(currentSerial: String?, nextSerial: String?) async throws -> PreActivationResult {
        // As in pair(): activation starts the wear clock, so don't activate a
        // sensor we couldn't then authorize.
        try await Self.ensureAppIdentities()
        #if targetEnvironment(simulator)
        let reader = LibreLoopSimulatedNFCReader()
        #else
        let reader = Libre3NFCActivationReader()
        #endif
        return try await Self.preActivate(
            reader: reader,
            receiverID: LibreLoopKeychain.appReceiverID(),
            currentSerial: currentSerial,
            nextSerial: nextSerial
        )
    }

    static func preActivate(
        reader: LibreLoopNFCScanning,
        receiverID: UInt32,
        currentSerial: String?,
        nextSerial: String?,
        now: () -> Date = Date.init
    ) async throws -> PreActivationResult {
        let scanResult: Libre3NFCScanResult
        do {
            scanResult = try await reader.scan(mode: .activateFreshSensor(receiverID: receiverID))
        } catch Libre3NFCError.unexpectedSensorState(let patchInfo) {
            let serial = patchInfo.serialNumber
            llog("next sensor: \(serial) is not factory-fresh (state 0x\(String(patchInfo.stateByte, radix: 16))); nothing sent")
            if serial == nextSerial { return .alreadyStarted(serial: serial) }
            if serial == currentSerial { return .sensorInUse(serial: serial) }
            switch patchInfo.stateByte {
            case 0x03: return .sensorInsertionFailed(serial: serial)
            case 0x05...0x08: return .sensorEnded(serial: serial)
            default: return .alreadyActive(serial: serial)
            }
        } catch {
            throw Failure.underlying("NFC scan failed: \(error.localizedDescription)")
        }
        guard scanResult.commandCode == .activate, let activation = scanResult.activationResponse else {
            throw Failure.nfcNoActivationResponse
        }
        let patchInfo = scanResult.patchInfo
        let activatedAt = Self.activationTime(sentIn: scanResult.commandParameters) ?? now()
        llog("next sensor: activated \(patchInfo.serialNumber) at \(activatedAt) bleAddress=\(activation.bleAddressDisplay)")
        return .activated(LibreLoopNextSensor(
            serial: patchInfo.serialNumber,
            activatedAt: activatedAt,
            warmupDurationMinutes: Int(patchInfo.warmupMinutes),
            wearDurationMinutes: Int(patchInfo.wearDurationMinutes),
            generation: patchInfo.generation,
            firmwareVersion: patchInfo.firmwareVersion,
            bleAddress: activation.bleAddressDisplay,
            receiverID: receiverID
        ))
    }

    /// The activation command's parameters start with the phone time it sent
    /// (seconds since 1970, little-endian), followed by the receiver ID.
    static func activationTime(sentIn parameters: Data?) -> Date? {
        guard let parameters, parameters.count >= 4 else { return nil }
        let bytes = [UInt8](parameters.prefix(4))
        let seconds = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Hands a successful NFC response to the caller only once it agrees to
    /// go on. A response it declines (the wrong sensor scanned) is never
    /// delivered, so it is never saved: nothing can reconnect to or pair it.
    /// A response it accepts is still delivered before any BLE work.
    static func handOverNFCResponse(
        _ response: NFCResponse,
        continueAfterNFC: (NFCResponse) async -> Bool,
        onNFCResponse: (NFCResponse) -> Void
    ) async throws {
        guard await continueAfterNFC(response) else {
            llog("NFC response for \(response.sensorSerial) declined; not saved")
            throw CancellationError()
        }
        onNFCResponse(response)
    }

    /// The pairing mode that switches to the next sensor: switch-receiver
    /// under the receiver ID it was activated with. That is the app's ID
    /// (`.fresh`) unless a recovery pairing has changed it since.
    static func switchMode(for next: LibreLoopNextSensor, appReceiverID: UInt32) -> Mode {
        guard let receiverID = next.receiverID, receiverID != appReceiverID else { return .fresh }
        return .recovery(receiverID: receiverID)
    }

    /// A Libre 3 advertises its BLE address, without colons, as its local name.
    static func localNameMatches(_ name: String?, bleAddress: String?) -> Bool {
        guard let name, let bleAddress, !bleAddress.isEmpty else { return false }
        return name.uppercased() == bleAddress.replacingOccurrences(of: ":", with: "").uppercased()
    }

    /// Whether a reconnect may take this peripheral: the saved peripheral when
    /// there is one, otherwise only one whose name is the saved BLE address --
    /// never just any Libre 3 in range, such as a next sensor warming up.
    static func reconnectAccepts(id: UUID, name: String?, expectedPeripheralID: UUID?, bleAddress: String?) -> Bool {
        if let expectedPeripheralID { return id == expectedPeripheralID }
        return localNameMatches(name, bleAddress: bleAddress)
    }
}

extension LibreLoopCGMManager {
    static let nextSensorReadyAlertID: Alert.AlertIdentifier = "nextSensorReady"

    public var nextSensor: LibreLoopNextSensor? { state.nextSensor }

    /// A next sensor can be started while a sensor is paired and none is
    /// waiting already.
    public var canStartNextSensorEarly: Bool {
        state.sensorSerial != nil && state.nextSensor == nil
    }

    /// Scans a new sensor and, when it is factory-fresh, activates it and keeps
    /// it as the next sensor. The current sensor's state, reconnect and BLE
    /// session are left alone.
    @MainActor
    public func startNextSensorEarly() async throws -> LibreLoopPairingService.PreActivationResult {
        try await startNextSensorEarly { current, next in
            try await LibreLoopPairingService().preActivate(currentSerial: current, nextSerial: next)
        }
    }

    @MainActor
    func startNextSensorEarly(
        preActivate: (_ currentSerial: String?, _ nextSerial: String?) async throws -> LibreLoopPairingService.PreActivationResult
    ) async throws -> LibreLoopPairingService.PreActivationResult {
        guard canStartNextSensorEarly else {
            throw LibreLoopPairingService.Failure.underlying(state.sensorSerial == nil
                ? "Pair a sensor before starting the next one."
                : "A next sensor has already been started.")
        }
        let result = try await preActivate(state.sensorSerial, state.nextSensor?.serial)
        if case .activated(let next) = result {
            var updated = state
            updated.nextSensor = next
            setState(updated)
            issueNextSensorReadyAlert(for: next)
        }
        return result
    }

    /// How the switch to the next sensor pairs it (see `switchMode`).
    public func pairingModeForSwitch(to next: LibreLoopNextSensor) -> LibreLoopPairingService.Mode {
        LibreLoopPairingService.switchMode(for: next, appReceiverID: LibreLoopKeychain.appReceiverID())
    }

    /// Stops tracking the next sensor. The sensor itself keeps running.
    public func forgetNextSensor() {
        guard let next = state.nextSensor else { return }
        llog("next sensor: forgetting \(next.serial)")
        var updated = state
        updated.nextSensor = nil
        setState(updated)
        retractNextSensorReadyAlert()
    }

    /// Once a sensor is adopted: clears the next sensor when it is the one
    /// adopted, or when this pairing was the switch to it and another sensor
    /// was confirmed instead. An ordinary replace with another sensor keeps it.
    public func clearNextSensorAfterAdopting(serial: String, switching: Bool) {
        guard let next = state.nextSensor, switching || next.serial == serial else { return }
        llog("next sensor: \(serial) adopted\(next.serial == serial ? "" : " instead of \(next.serial)")")
        forgetNextSensor()
    }

    private func issueNextSensorReadyAlert(for next: LibreLoopNextSensor, now: Date = Date()) {
        let delay = next.readyAt.timeIntervalSince(now)
        guard delay > 0 else { return }
        let title = LocalizedString("Next sensor ready", comment: "Next-sensor-ready alert title")
        let body = LocalizedString("Your next FreeStyle Libre 3 sensor has finished warming up. Switch to it in the CGM settings whenever you're ready.", comment: "Next-sensor-ready alert body")
        let ok = LocalizedString("OK", comment: "Alert acknowledge button")
        let content = Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: ok)
        let alert = Alert(
            identifier: Alert.Identifier(managerIdentifier: pluginIdentifier, alertIdentifier: Self.nextSensorReadyAlertID),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .delayed(interval: delay),
            interruptionLevel: .active
        )
        cgmDelegate.notify { delegate in await delegate?.issueAlert(alert) }
    }

    private func retractNextSensorReadyAlert() {
        let identifier = Alert.Identifier(managerIdentifier: pluginIdentifier, alertIdentifier: Self.nextSensorReadyAlertID)
        cgmDelegate.notify { delegate in await delegate?.retractAlert(identifier: identifier) }
    }

    /// Where a backfill request starts: after the saved watermark (less a
    /// small overlap), or ~15 h back on a first session -- but never at or
    /// before the previous sensor's last reading, so a sensor that was started
    /// early doesn't import its warm-up and overlap readings on top of it.
    static func backfillStartLifeCount(
        currentLifeCount: UInt16,
        readingAt: Date,
        watermark: UInt16?,
        previousSensorLastReadingAt: Date?
    ) -> UInt16 {
        var from: UInt16
        if let watermark {
            let overlap: UInt16 = 10
            from = watermark > overlap ? watermark &- overlap : 5
        } else {
            let lookback: UInt16 = 180
            from = currentLifeCount > lookback ? currentLifeCount &- lookback : 5
        }
        if let previous = previousSensorLastReadingAt {
            let minutesSince = Int((readingAt.timeIntervalSince(previous) / 60).rounded(.down))
            let firstAfter = min(Int(currentLifeCount), Int(currentLifeCount) - minutesSince + 1)
            if firstAfter > Int(from) {
                from = UInt16(clamping: firstAfter)
            }
        }
        return from
    }

    /// How long after the previous sensor's last reading its cutoff is kept.
    /// Past it every backfill request starts well after the cutoff anyway:
    /// the watermark follows the readings and requests reach back at most 10
    /// lifeCounts from it (pass 2: 5), and the first session's 180-count
    /// (3 h) lookback, with pages that may start a little before the request,
    /// stays clear of a cutoff 6 h back.
    static let previousSensorCutoffRetention: TimeInterval = 6 * 60 * 60

    /// Whether a realtime reading at `readingAt` still needs the previous
    /// sensor's cutoff. A reading dated at or before it can only come from a
    /// phone clock that stepped backwards (the cutoff is saved before the
    /// next pairing even starts); the cutoff would then drop this sensor's
    /// own backfill, so it is cleared rather than kept.
    static func keepsPreviousSensorCutoff(_ cutoff: Date, readingAt: Date) -> Bool {
        readingAt > cutoff && readingAt.timeIntervalSince(cutoff) <= previousSensorCutoffRetention
    }

    /// Backfill dated at or before the previous sensor's last reading belongs
    /// to the time that sensor already covered.
    func isBackfillOverlappingPreviousSensor(_ date: Date) -> Bool {
        guard let previous = state.previousSensorLastReadingAt else { return false }
        return date <= previous
    }
}
