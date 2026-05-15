import Foundation
import CoreBluetooth
import Security
import LibreCRKit

/// Orchestrates a fresh Libre 3 sensor pairing:
///   1. CoreNFC activation (provides bleAddress + blePIN + sensor serial)
///   2. BLE scan + connect to the just-activated sensor
///   3. Cryptographic first-pair handshake (yields kEnc + ivEnc)
///
/// Hides LibreCRKit from upper layers (UI, CGMManager) so we can swap
/// implementations later without rewriting callers.
public final class LibreLoopPairingService {

    public struct Result: Sendable, Equatable {
        public let receiverID: UInt32
        public let sensorSerial: String
        public let bleAddress: String?
        public let blePIN: Data
        public let activatedAt: Date
        public let kEnc: Data
        public let ivEnc: Data
    }

    /// Intermediate state captured immediately after a successful NFC
    /// activation / switch-receiver. Must be persisted before BLE
    /// authentication is attempted (per LibreCRKit author guidance: each A8
    /// burns the previous BLE PIN; losing this one strands the sensor).
    public struct NFCResponse: Sendable, Equatable {
        public let receiverID: UInt32
        public let sensorSerial: String
        public let bleAddress: String?
        public let blePIN: Data
        /// Sensor activation timestamp. Often nil at NFC time -- the value
        /// is filled in once the first glucose reading arrives and we can
        /// back-derive from its lifeCount.
        public let activatedAt: Date?
    }

    public struct PairOutcomeMetadata: Sendable {
        /// CBPeripheral identifier captured during pairing scan. Used by
        /// reconnect to match the exact peripheral instead of accepting any
        /// discovered Libre 3 sensor.
        public let peripheralID: UUID
    }

    public enum Stage: Sendable, Equatable {
        case nfcScanning
        case bleSearching
        case bleConnecting
        case handshaking
    }

    public enum Failure: Error, CustomStringConvertible {
        case nfcNoActivationResponse
        case bleNoSensorDiscovered
        case entropy(OSStatus)
        case underlying(String)

        public var description: String {
            switch self {
            case .nfcNoActivationResponse:
                return "No activation response from the sensor. Try scanning again."
            case .bleNoSensorDiscovered:
                return "Couldn't find the sensor over Bluetooth. Make sure the sensor is on your arm and Bluetooth is on."
            case .entropy(let status):
                return "Couldn't generate cryptographic entropy (OSStatus \(status))."
            case .underlying(let message):
                return message
            }
        }
    }

    public init() {}

    /// Re-establish a BLE session against an already-paired sensor using the
    /// saved BLE PIN. No NFC -- this is what gets called when the BLE link
    /// drops mid-session (sensor went out of range, iOS reaped the link, etc).
    ///
    /// LibreCRKit has no reconnect-with-saved-keys API, so we re-run the
    /// candidate first-pair handshake against the same blePIN. The sensor
    /// accepts the same PIN until another A8 burns it. Each reconnect
    /// produces fresh kEnc/ivEnc, which the caller must persist.
    public func reconnect(
        scanner: SensorScanner,
        blePIN: Data,
        expectedPeripheralID: UUID? = nil,
        scanTimeout: TimeInterval = 120,
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> ReconnectOutcome {
        onStage(.bleSearching)
        try await scanner.waitUntilReady()

        // Fast path: when we have a peripheralID from a prior pair, ask iOS
        // for the peripheral directly. CB will deliver the connection when
        // the peripheral is in range -- no active scanning needed, which
        // avoids the long-running-scan throttling that breaks reconnect
        // after several hours. Scanning is reserved for initial pair only.
        var peripheral: CBPeripheral?
        if let id = expectedPeripheralID {
            let retrieved = await scanner.retrievePeripherals(withIdentifiers: [id])
            peripheral = retrieved.first
        }

        // Fallback: no saved peripheralID or iOS doesn't know it (BLE
        // state wiped, sensor never paired with this device). Fall back
        // to a bounded scan.
        if peripheral == nil {
            peripheral = try await Self.scanForPeripheral(
                scanner: scanner,
                matching: expectedPeripheralID,
                timeout: scanTimeout
            )
        }
        guard let peripheral else { throw Failure.bleNoSensorDiscovered }

        onStage(.bleConnecting)
        let session: SensorSession
        do {
            session = try await scanner.connect(peripheral, timeout: 120)
        } catch {
            throw Failure.underlying("BLE connection failed: \(error.localizedDescription)")
        }

        onStage(.handshaking)
        let transport = SensorSessionTransport(session: session)
        let phoneCert = try Self.loadBundled162bCert()
        let nativeEphemeral = try SessionKey.makeFirstPairNativeEphemeral(
            entropySource: Self.secureRandomBytes(count:)
        )
        let pairingFlow = PairingFlow(
            transport: transport,
            phoneCert: phoneCert,
            phoneEph: nativeEphemeral.keyPair,
            eventLogger: nil
        )

        let handshake: FirstPairDerivedHandshakeResult
        do {
            handshake = try await pairingFlow.runCommandGatedFirstPairHandshake(
                blePIN: blePIN,
                maxEntropyAttempts: 1,
                entropySource: { count in
                    guard count == nativeEphemeral.nullEntropy11A.count else {
                        throw Failure.underlying("Entropy size mismatch (\(count) vs \(nativeEphemeral.nullEntropy11A.count))")
                    }
                    return nativeEphemeral.nullEntropy11A
                },
                r2Provider: { try Self.secureRandomBytes(count: 16) }
            )
        } catch {
            throw Failure.underlying("Reconnect handshake failed: \(error.localizedDescription)")
        }

        let material = handshake.handshake.sessionMaterial
        let monitor = try LibreLoopSensorMonitor.make(
            scanner: scanner,
            session: session,
            kEnc: material.kEnc,
            ivEnc: material.ivEnc
        )
        return ReconnectOutcome(monitor: monitor, kEnc: material.kEnc, ivEnc: material.ivEnc)
    }

    public struct ReconnectOutcome {
        public let monitor: LibreLoopSensorMonitor
        public let kEnc: Data
        public let ivEnc: Data
    }

    public struct PairOutcome {
        public let result: Result
        public let monitor: LibreLoopSensorMonitor
        public let peripheralID: UUID
    }

    public enum Mode: Sendable, Equatable {
        /// Brand-new sensor, never paired before. Generates a fresh receiverID.
        case fresh
        /// Reconnect to a sensor that's already been paired with this app
        /// (or with the LibreCRKit PoC) under a known receiverID. The sensor
        /// only accepts switch-receiver from the same receiverID it remembers.
        case recovery(receiverID: UInt32)
    }

    public func pair(
        mode: Mode = .fresh,
        scanner: SensorScanner,
        onNFCResponse: @Sendable @escaping (NFCResponse) -> Void = { _ in },
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> PairOutcome {
        // 1. NFC activation. Switch-receiver only succeeds when the receiverID
        // matches what the sensor remembers; pass-through here, the sensor
        // validates server-side.
        onStage(.nfcScanning)
        let nfcReader = Libre3NFCActivationReader()
        let scanResult: Libre3NFCScanResult
        let receiverID: UInt32
        let scanMode: Libre3NFCScanMode
        switch mode {
        case .fresh:
            receiverID = UInt32.random(in: 1...UInt32.max)
            scanMode = .activateFreshSensor(receiverID: receiverID, timeSeconds: nil)
        case .recovery(let id):
            receiverID = id
            scanMode = .switchReceiver(receiverID: id, timeSeconds: nil)
        }
        do {
            scanResult = try await nfcReader.scan(mode: scanMode)
        } catch {
            throw Failure.underlying("NFC scan failed: \(error.localizedDescription)")
        }
        guard let activation = scanResult.activationResponse else {
            throw Failure.nfcNoActivationResponse
        }

        // Persist NFC response IMMEDIATELY. If anything below fails -- BLE
        // scan, connect, or handshake -- the caller still has the receiverID
        // and (new) blePIN. Losing the blePIN after a successful A8 strands
        // the sensor until another A8 burns yet another PIN.
        //
        // activatedAt is intentionally nil here. patchInfo.wearDurationMinutes
        // turned out to be sensor *lifetime capacity*, not current age. The
        // real activation timestamp is derived from the first glucose
        // reading's lifeCount (sample.date - lifeCount minutes).
        let nfcResponse = NFCResponse(
            receiverID: receiverID,
            sensorSerial: scanResult.patchInfo.serialNumber,
            bleAddress: activation.bleAddressDisplay,
            blePIN: activation.blePIN,
            activatedAt: nil
        )
        onNFCResponse(nfcResponse)

        // 2. BLE scan + connect
        onStage(.bleSearching)
        try await scanner.waitUntilReady()

        var discovered: DiscoveredSensor?
        for await sensor in scanner.startScan() {
            discovered = sensor
            break
        }
        guard let sensor = discovered else {
            throw Failure.bleNoSensorDiscovered
        }

        onStage(.bleConnecting)
        let session: SensorSession
        do {
            session = try await scanner.connect(sensor.peripheral, timeout: 120)
        } catch {
            throw Failure.underlying("BLE connection failed: \(error.localizedDescription)")
        }

        // 3. Handshake -- candidate path with phone_cert_162b (03 03 family).
        //
        // phone_cert_firstpair.bin (the LibreCRKit-shipped default) has known
        // live-sensor rejection, so we vendor phone_cert_162b.bin from the
        // upstream PoC and follow the PoC's candidate Phase 5 flow:
        //   - native ephemeral derived via SessionKey.makeFirstPairNativeEphemeral
        //   - maxEntropyAttempts: 1
        //   - Phase 5 entropy = nativeEphemeral.nullEntropy11A
        onStage(.handshaking)
        let transport = SensorSessionTransport(session: session)
        let phoneCert = try Self.loadBundled162bCert()
        let nativeEphemeral = try SessionKey.makeFirstPairNativeEphemeral(
            entropySource: Self.secureRandomBytes(count:)
        )
        let pairingFlow = PairingFlow(
            transport: transport,
            phoneCert: phoneCert,
            phoneEph: nativeEphemeral.keyPair,
            eventLogger: nil
        )

        let handshake: FirstPairDerivedHandshakeResult
        do {
            handshake = try await pairingFlow.runCommandGatedFirstPairHandshake(
                blePIN: activation.blePIN,
                maxEntropyAttempts: 1,
                entropySource: { requestedCount in
                    guard requestedCount == nativeEphemeral.nullEntropy11A.count else {
                        throw Failure.underlying(
                            "Entropy size mismatch (need \(requestedCount), have \(nativeEphemeral.nullEntropy11A.count))"
                        )
                    }
                    return nativeEphemeral.nullEntropy11A
                },
                r2Provider: { try Self.secureRandomBytes(count: 16) }
            )
        } catch {
            throw Failure.underlying("Pairing handshake failed: \(error.localizedDescription)")
        }

        let material = handshake.handshake.sessionMaterial
        let result = Result(
            receiverID: receiverID,
            sensorSerial: scanResult.patchInfo.serialNumber,
            bleAddress: activation.bleAddressDisplay,
            blePIN: activation.blePIN,
            activatedAt: nfcResponse.activatedAt ?? Date(),
            kEnc: material.kEnc,
            ivEnc: material.ivEnc
        )
        let monitor = try LibreLoopSensorMonitor.make(
            scanner: scanner,
            session: session,
            kEnc: material.kEnc,
            ivEnc: material.ivEnc
        )
        return PairOutcome(result: result, monitor: monitor, peripheralID: sensor.id)
    }

    private static func scanForPeripheral(
        scanner: SensorScanner,
        matching expectedPeripheralID: UUID?,
        timeout: TimeInterval
    ) async throws -> CBPeripheral {
        let sensor: DiscoveredSensor = try await withThrowingTaskGroup(of: DiscoveredSensor?.self) { group in
            group.addTask {
                for await found in scanner.startScan() {
                    if expectedPeripheralID == nil || found.id == expectedPeripheralID {
                        return found
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            for try await result in group {
                group.cancelAll()
                if let result { return result }
                throw Failure.bleNoSensorDiscovered
            }
            throw Failure.bleNoSensorDiscovered
        }
        return sensor.peripheral
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.entropy(status) }
        return Data(buffer)
    }

    private static func loadBundled162bCert() throws -> PhoneCert {
        let bundle = Bundle(for: LibreLoopCGMManager.self)
        guard let url = bundle.url(forResource: "phone_cert_162b", withExtension: "bin") else {
            throw Failure.underlying("phone_cert_162b.bin missing from LibreLoop.framework. Rebuild required.")
        }
        return try PhoneCert(raw: try Data(contentsOf: url))
    }
}
