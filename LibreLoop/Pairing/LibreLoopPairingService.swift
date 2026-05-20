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
        /// Phase 5 raw key from first-pair handshake. Needed for the
        /// `runCachedReconnectHandshake` fast-path on subsequent reconnects;
        /// callers must persist this alongside kEnc/ivEnc. Nil only on
        /// legacy/cached reconnect outcomes where the value isn't re-derived.
        public let phase5RawKey: Data?
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

    /// Re-establish a BLE session against an already-paired sensor.
    ///
    /// If `phase5RawKey` is non-nil (saved from a prior successful pair on
    /// this app), tries LibreCRKit's `runCachedReconnectHandshake` first:
    /// `0x11 StartAuthorization` → `R1/nonce notify` → Phase 5 (using the
    /// cached raw key) → `0x08` → Phase 6. Skips cert + ephemeral exchange,
    /// trimming the handshake from 8 BLE commands to 2.
    ///
    /// If the cached path fails before Phase 6 (or `phase5RawKey` is nil),
    /// falls back to the full first-pair-style handshake against the saved
    /// blePIN. Each reconnect produces fresh kEnc/ivEnc that the caller
    /// must persist; the fast/cached path also returns a new phase5RawKey
    /// on success only when the fallback ran (cached reuses the existing
    /// one).
    public func reconnect(
        scanner: SensorScanner,
        blePIN: Data,
        phase5RawKey: Data? = nil,
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

        // G7-style fallback: if retrievePeripherals(withIdentifiers:)
        // didn't return our peripheral (iOS may have evicted the cached
        // identifier after a long suspension), ask iOS for any peripheral
        // it considers connected that advertises the Libre 3 service.
        // The OS often holds the link from a prior session/restore and
        // we don't need to scan or even reconnect at the OS level.
        if peripheral == nil {
            let connected = await scanner.retrieveConnectedPeripherals()
            if let id = expectedPeripheralID {
                peripheral = connected.first { $0.identifier == id }
            } else {
                peripheral = connected.first
            }
            if peripheral != nil {
                llog("pre-connect: recovered peripheral from retrieveConnectedPeripherals (no retrievePeripherals match)")
            }
        }

        // Final fallback: scan. Bounded so we don't burn the radio
        // forever waiting for a sensor that might never show up.
        if peripheral == nil {
            peripheral = try await Self.scanForPeripheral(
                scanner: scanner,
                matching: expectedPeripheralID,
                timeout: scanTimeout
            )
        }
        guard let peripheral else { throw Failure.bleNoSensorDiscovered }

        // Re-check the central manager is still .poweredOn. We checked
        // at the top of reconnect (waitUntilReady before peripheral
        // retrieval), but state can flip between then and now — airplane
        // mode toggle, BT off, simulator reset, system BT crash. connect
        // against a non-poweredOn central silently fails. waitUntilReady
        // returns immediately if already .poweredOn, suspends if
        // transitioning, throws on terminal states.
        try await scanner.waitUntilReady()

        // Make sure the peripheral is in a clean .disconnected state.
        // Previously abandoned attempts may have left it in .connecting
        // (pending connect iOS is still holding) or phantom-.connected;
        // in either case a new connect either queues behind the stale
        // request or no-ops.
        let preState = await scanner.state(of: peripheral)
        if preState != .disconnected {
            llog("pre-connect: peripheral state=\(String(describing: preState)); forcing disconnect")
            await scanner.ensureDisconnected(peripheralID: peripheral.identifier)
            let postState = await scanner.state(of: peripheral)
            llog("pre-connect: post-cancel state=\(String(describing: postState))")
        }

        onStage(.bleConnecting)
        let session: SensorSession
        do {
            // No timeout on reconnect: iOS will hold the pending connect
            // and call didConnect when the peripheral comes back in range,
            // including waking us from suspension (bluetooth-central +
            // state restoration). Our previous 120s timeout fought iOS by
            // tearing down the queued connect and retrying from scratch,
            // which produced churn in the BLE stack and burned bg-task
            // budget. Initial pair (above) keeps its 120s timeout because
            // the user is staring at a UI and we need to surface a clear
            // failure if the sensor isn't reachable.
            session = try await scanner.connect(peripheral, timeout: 0)
        } catch {
            throw Failure.underlying("BLE connection failed: \(error.localizedDescription)")
        }

        onStage(.handshaking)
        let transport = SensorSessionTransport(session: session)

        // Try the upstream cached/direct reconnect first if we have material
        // for it. On any failure short-circuits to the full handshake path
        // below -- upstream's guidance is "if it is rejected before Phase 6,
        // fall back to the full authorization path".
        if let phase5RawKey {
            let cachedFlow = PairingFlow(transport: transport, eventLogger: { message in llog(message) })
            do {
                let cached = try await cachedFlow.runCachedReconnectHandshake(
                    tail4: blePIN,
                    phase5RawKey: phase5RawKey,
                    r2Provider: { try Self.secureRandomBytes(count: 16) }
                )
                let material = cached.sessionMaterial
                let monitor = try LibreLoopSensorMonitor.make(
                    scanner: scanner,
                    session: session,
                    kEnc: material.kEnc,
                    ivEnc: material.ivEnc
                )
                return ReconnectOutcome(
                    monitor: monitor,
                    kEnc: material.kEnc,
                    ivEnc: material.ivEnc,
                    phase5RawKey: nil,
                    path: .cached
                )
            } catch {
                // Continue to full-handshake fallback below.
            }
        }

        let phoneCert = try Self.loadBundled162bCert()
        let nativeEphemeral = try SessionKey.makeFirstPairNativeEphemeral(
            entropySource: Self.secureRandomBytes(count:)
        )
        let pairingFlow = PairingFlow(
            transport: transport,
            phoneCert: phoneCert,
            phoneEph: nativeEphemeral.keyPair,
            eventLogger: { message in llog(message) }
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
        return ReconnectOutcome(
            monitor: monitor,
            kEnc: material.kEnc,
            ivEnc: material.ivEnc,
            phase5RawKey: handshake.phase5Material.rawKey,
            path: .fullFallback
        )
    }

    public struct ReconnectOutcome {
        public let monitor: LibreLoopSensorMonitor
        public let kEnc: Data
        public let ivEnc: Data
        /// Newly-derived Phase 5 raw key when the full fallback path runs;
        /// nil when the cached/direct path succeeded (reuses the existing
        /// cached key, no re-derivation).
        public let phase5RawKey: Data?
        public let path: Path
        public enum Path: Sendable, Equatable { case cached, fullFallback }
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
        do {
            switch mode {
            case .fresh:
                let freshID = UInt32.random(in: 1...UInt32.max)
                // Auto-recover: if the sensor is already activated and we
                // have a stored receiverID in Keychain for its serial, the
                // NFC reader will issue switchReceiver with the stored ID
                // instead of failing. Capture which ID actually got used.
                let actualReceiverID = ReceiverIDBox(initial: freshID)
                scanResult = try await nfcReader.scan(
                    activateReceiverID: freshID,
                    recoverReceiverIDForSerial: { serial in
                        guard let keys = try? LibreLoopKeychain.load(forSensorSerial: serial),
                              let stored = keys.receiverID else {
                            return nil
                        }
                        actualReceiverID.value = stored
                        return stored
                    }
                )
                receiverID = actualReceiverID.value
            case .recovery(let id):
                receiverID = id
                scanResult = try await nfcReader.scan(mode: .switchReceiver(receiverID: id, timeSeconds: nil))
            }
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
            eventLogger: { message in llog(message) }
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
            ivEnc: material.ivEnc,
            phase5RawKey: handshake.phase5Material.rawKey
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

/// Reference cell for capturing which receiverID the NFC reader ended up
/// using, since the recovery lookup closure can override the caller's
/// initial guess at scan time.
private final class ReceiverIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt32
    init(initial: UInt32) { _value = initial }
    var value: UInt32 {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
