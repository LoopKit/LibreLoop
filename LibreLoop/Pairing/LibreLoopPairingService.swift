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
        /// Total sensor wear duration in minutes from the NFC patch-info.
        /// Distinguishes Libre 3 (14-day) from Libre 3 Plus (15-day) and
        /// any future variants without hardcoding sensor-family durations.
        public let wearDurationMinutes: Int?
        /// Sensor-reported warmup duration in minutes from the NFC patch
        /// info (byte 16 × 5). Replaces the hardcoded 60-min default and
        /// is what we count down from on the lifecycle bar.
        public let warmupDurationMinutes: Int?
        /// NFC patch-info `generation` field. 0 = Libre 3,
        /// 1 = Libre 3 Plus / Instinct. Direct sensor-family discriminator.
        public let generation: UInt16?
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
        scanner: SensorScannerNG,
        blePIN: Data,
        phase5RawKey: Data? = nil,
        expectedPeripheralID: UUID? = nil,
        scanTimeout: TimeInterval = 120,
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> ReconnectOutcome {
        onStage(.bleSearching)
        try await Self.awaitReady(scanner: scanner)

        // Fast path: when we have a peripheralID from a prior pair, ask iOS
        // for the peripheral directly. CB will deliver the connection when
        // the peripheral is in range -- no active scanning needed, which
        // avoids the long-running-scan throttling that breaks reconnect
        // after several hours. Scanning is reserved for initial pair only.
        var peripheral: CBPeripheral?
        if let id = expectedPeripheralID {
            let retrieved = scanner.retrievePeripherals(withIdentifiers: [id])
            peripheral = retrieved.first
        }

        // G7-style fallback: if retrievePeripherals(withIdentifiers:)
        // didn't return our peripheral (iOS may have evicted the cached
        // identifier after a long suspension), ask iOS for any peripheral
        // it considers connected that advertises the Libre 3 service.
        // The OS often holds the link from a prior session/restore and
        // we don't need to scan or even reconnect at the OS level.
        if peripheral == nil {
            let connected = scanner.retrieveConnectedPeripherals()
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
            peripheral = try await Self.scanForPeripheralNG(
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
        try await Self.awaitReady(scanner: scanner)

        // Do NOT cancel a pending .connecting state before calling connect().
        // G7 never does this either: CB deduplicates redundant connect() calls,
        // and cancelling a pending connect tears down the indefinite iOS-held
        // request that would have woken us from suspension when the sensor
        // came in range — creating a window where iOS has no connect queued.
        return try await Self.withDisconnectWatchdog(scanner: scanner, peripheralID: peripheral.identifier) { sessionBox in
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
                session = try await Self.connectAndBuildSession(
                    scanner: scanner,
                    peripheral: peripheral,
                    timeout: 0
                )
            } catch {
                throw Failure.underlying("BLE connection failed: \(error.localizedDescription)")
            }
            // Hand the session to the watchdog: any .didDisconnect for
            // this peripheral from now on will fail the session's
            // pending writes/reads/notify changes, which makes the
            // handshake awaits below throw promptly instead of
            // hanging on a CB read that will never return.
            sessionBox.set(session)

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
        scanner: SensorScannerNG,
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
                // activateOrSwitchReceiver picks the right NFC command based
                // on the sensor's state byte: activate if the sensor is still
                // in the factory state, switchReceiver if it's already paired.
                // This handles the common case of re-scanning a sensor that
                // this app previously activated. For recovery with a known
                // receiverID from a different source use .recovery(receiverID:).
                scanResult = try await nfcReader.scan(mode: .activateOrSwitchReceiver(receiverID: freshID))
                receiverID = freshID
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
        // For .fresh mode, the sensor was just activated by us, so we know
        // activatedAt = now to within a few seconds. Seed it so the lifecycle
        // drops straight into .warmup once BLE pair completes instead of
        // showing .initializing for the ~minute it takes the first realtime
        // reading to arrive. The first reading (lifeCount 0 or 1) is then
        // suppressed by the nil-guard in ingest(), avoiding any jitter.
        //
        // For .recovery (switch-receiver), the sensor was activated some
        // unknown time ago; we still rely on the first reading's lifeCount.
        let activatedAtFromNFC: Date?
        switch mode {
        case .fresh:    activatedAtFromNFC = Date()
        case .recovery: activatedAtFromNFC = nil
        }
        let nfcResponse = NFCResponse(
            receiverID: receiverID,
            sensorSerial: scanResult.patchInfo.serialNumber,
            bleAddress: activation.bleAddressDisplay,
            blePIN: activation.blePIN,
            activatedAt: activatedAtFromNFC,
            wearDurationMinutes: Int(scanResult.patchInfo.wearDurationMinutes),
            warmupDurationMinutes: Int(scanResult.patchInfo.warmupMinutes),
            generation: scanResult.patchInfo.generation
        )
        onNFCResponse(nfcResponse)

        // 2. BLE scan + connect
        onStage(.bleSearching)
        try await Self.awaitReady(scanner: scanner)

        let sensor = try await Self.scanForAnyPeripheralNG(scanner: scanner, timeout: 120)

        onStage(.bleConnecting)
        let session: SensorSession
        do {
            session = try await Self.connectAndBuildSession(
                scanner: scanner,
                peripheral: sensor.peripheral,
                timeout: 120
            )
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

    // MARK: - SensorScannerNG event-stream adapters
    //
    // These translate the new event-driven scanner into the synchronous-
    // await patterns the pair / reconnect flows are written against.
    // They live here rather than in SensorScannerNG itself because the
    // "wait for callback X" pattern is the caller's policy choice --
    // the scanner deliberately doesn't take a position on timeouts.

    /// Suspend until the scanner reports `.poweredOn`. Throws on a
    /// terminal state (poweredOff, unauthorized, unsupported), or
    /// propagates CancellationError if the surrounding Task is
    /// cancelled before the state settles.
    static func awaitReady(scanner: SensorScannerNG) async throws {
        if let immediate = stateOutcome(scanner.centralState) {
            switch immediate {
            case .ready: return
            case .error(let e): throw e
            case .pending: break
            }
        }
        for await event in scanner.events() {
            try Task.checkCancellation()
            if case .stateChanged(let s) = event, let outcome = stateOutcome(s) {
                switch outcome {
                case .ready: return
                case .error(let e): throw e
                case .pending: continue
                }
            }
        }
        // for-await exited without a usable .stateChanged event. Three
        // possibilities, in order:
        //   1. Surrounding Task was cancelled -- propagate that.
        //   2. central settled between the head snapshot and the
        //      subscription (less likely now that events() replays the
        //      current state, but still possible if state flips twice
        //      in a tight window) -- re-check and act.
        //   3. The events() stream actually finished (scanner being
        //      torn down) -- fall back to .bluetoothUnavailable.
        try Task.checkCancellation()
        if let outcome = stateOutcome(scanner.centralState) {
            switch outcome {
            case .ready: return
            case .error(let e): throw e
            case .pending: break
            }
        }
        throw SensorScannerError.bluetoothUnavailable
    }

    private enum StateOutcome { case ready, pending, error(SensorScannerError) }
    private static func stateOutcome(_ s: CBManagerState) -> StateOutcome? {
        switch s {
        case .poweredOn: return .ready
        case .poweredOff: return .error(.bluetoothPoweredOff)
        case .unauthorized: return .error(.bluetoothUnauthorized)
        case .unsupported: return .error(.bluetoothUnavailable)
        case .resetting, .unknown: return .pending
        @unknown default: return .error(.bluetoothUnavailable)
        }
    }

    /// Issue `requestConnect`, wait for `.didConnect` matching the
    /// requested peripheral, then build a fully-discovered SensorSession.
    /// Throws on `.didFailToConnect` or `.didDisconnect` for the same
    /// peripheral. `timeout = 0` means "never time out at this layer"
    /// (caller is responsible for cancellation).
    static func connectAndBuildSession(
        scanner: SensorScannerNG,
        peripheral: CBPeripheral,
        timeout: TimeInterval
    ) async throws -> SensorSession {
        let pid = peripheral.identifier
        // Issue the connect request before subscribing -- CB queues
        // it idempotently, and if the peripheral is already connected
        // we'd otherwise miss the (already-fired) didConnect event.
        // Handle the already-connected case explicitly below.
        if peripheral.state == .connected {
            let session = SensorSession(peripheral: peripheral, queue: scanner.centralQueue)
            try await session.discoverAndSubscribe()
            return session
        }
        llog("ble: requesting connect \(peripheral.identifier.uuidString) (handshake)")
        scanner.requestConnect(peripheral)
        let connectedPeripheral: CBPeripheral = try await withEventStream(
            scanner: scanner,
            timeout: timeout,
            timeoutError: SensorScannerError.timeout("connect timed out after \(Int(timeout))s")
        ) { event in
            switch event {
            case .didConnect(let p) where p.identifier == pid:
                return .done(p)
            case .didFailToConnect(let p, let err) where p.identifier == pid:
                return .throwing(SensorScannerError.connectionFailed(err?.localizedDescription ?? "unknown"))
            case .didDisconnect(let p, let err) where p.identifier == pid:
                return .throwing(SensorScannerError.connectionFailed(err?.localizedDescription ?? "disconnected"))
            default:
                return .continue
            }
        }
        let session = SensorSession(peripheral: connectedPeripheral, queue: scanner.centralQueue)
        try await session.discoverAndSubscribe()
        return session
    }

    /// Start a scan and yield the first peripheral matching `expectedID`
    /// (or any peripheral if `expectedID` is nil). Stops the scan on
    /// completion.
    static func scanForPeripheralNG(
        scanner: SensorScannerNG,
        matching expectedID: UUID?,
        timeout: TimeInterval
    ) async throws -> CBPeripheral {
        scanner.startScan()
        defer { scanner.stopScan() }
        let discovered: DiscoveredSensor = try await withEventStream(
            scanner: scanner,
            timeout: timeout,
            timeoutError: Failure.bleNoSensorDiscovered
        ) { event in
            if case .didDiscover(let d) = event, expectedID == nil || d.id == expectedID {
                return .done(d)
            }
            return .continue
        }
        return discovered.peripheral
    }

    /// Like `scanForPeripheralNG` but returns the first discovery
    /// regardless of UUID. Used by initial pair where we don't yet know
    /// the peripheral identifier.
    static func scanForAnyPeripheralNG(
        scanner: SensorScannerNG,
        timeout: TimeInterval
    ) async throws -> DiscoveredSensor {
        scanner.startScan()
        defer { scanner.stopScan() }
        return try await withEventStream(
            scanner: scanner,
            timeout: timeout,
            timeoutError: Failure.bleNoSensorDiscovered
        ) { event in
            if case .didDiscover(let d) = event { return .done(d) }
            return .continue
        }
    }

    private enum EventStreamStep<T> {
        case `continue`
        case done(T)
        case throwing(Error)
    }

    /// Compose a one-shot consumer of `scanner.events()` that walks
    /// events until the matcher resolves. Adds a single optional
    /// wall-clock timeout. The matcher runs synchronously on the
    /// event-delivery thread; the result is returned to the caller.
    private static func withEventStream<T>(
        scanner: SensorScannerNG,
        timeout: TimeInterval,
        timeoutError: @autoclosure @escaping () -> Error,
        matcher: @escaping (SensorScannerNG.Event) -> EventStreamStep<T>
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                for await event in scanner.events() {
                    switch matcher(event) {
                    case .continue: continue
                    case .done(let value): return value
                    case .throwing(let error): throw error
                    }
                }
                throw timeoutError()
            }
            if timeout > 0 {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw timeoutError()
                }
            }
            defer { group.cancelAll() }
            // First task to finish wins; cancel the others.
            if let result = try await group.next() {
                return result
            }
            throw timeoutError()
        }
    }

    /// Holds a SensorSession reference accessible from both the
    /// main reconnect Task and a sibling disconnect-watchdog Task.
    /// `final class` so swapping the value via a shared reference is
    /// thread-safe; mutation guarded by an NSLock.
    final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SensorSession?
        func set(_ session: SensorSession?) {
            lock.lock(); defer { lock.unlock() }
            value = session
        }
        func get() -> SensorSession? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Run an operation against a session built mid-flight, failing
    /// the session on a CoreBluetooth `.didDisconnect` for the
    /// peripheral. Closes the gap where SensorSession.pendingWrites
    /// (used by PairingFlow during the handshake) would otherwise
    /// hang forever if the link dropped between requestConnect and
    /// handshake completion -- the original 98-min outage shape.
    ///
    /// Caller is responsible for calling `box.set(session)` as soon
    /// as the session is built so the watchdog can fail it. Before
    /// that point, a disconnect is surfaced through
    /// connectAndBuildSession throwing on the awaited
    /// .didConnect/.didDisconnect event.
    static func withDisconnectWatchdog<T>(
        scanner: SensorScannerNG,
        peripheralID: UUID,
        body: (SessionBox) async throws -> T
    ) async throws -> T {
        let box = SessionBox()
        let watchdog = Task<Void, Never> {
            for await event in scanner.events() {
                if case .didDisconnect(_, let err) = event {
                    // Capture the current session under the lock; if
                    // any operation is in flight on it, this makes
                    // their pending CheckedContinuations throw
                    // SensorSessionError.disconnected.
                    box.get()?.handleDisconnect(error: err)
                    return
                }
                if Task.isCancelled { return }
            }
        }
        defer { watchdog.cancel() }
        return try await body(box)
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
