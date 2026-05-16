import Foundation
import CoreBluetooth
import LibreCRKit
import os.log


/// Wraps a live `SensorSession` after pairing has succeeded. Decrypts
/// glucose-channel notifications using the session keys (`kEnc`/`ivEnc`)
/// and surfaces usable readings via a callback.
///
/// Lifetime: monitor is alive only while the underlying BLE session is
/// connected. LibreCRKit has no reconnect-with-saved-keys API, so an
/// app kill or out-of-range disconnect requires a re-pair to resume.
public final class LibreLoopSensorMonitor: @unchecked Sendable {
    public typealias ReadingHandler = @Sendable (LibreLoopGlucoseSample) -> Void
    public typealias DisconnectHandler = @Sendable () -> Void
    public typealias StatusHandler = @Sendable (String) -> Void
    public typealias HistoricalPageHandler = @Sendable (HistoricalReadingPage) -> Void
    /// Fires once the post-auth CCCD refresh completes and the monitor is
    /// ready to accept commands (backfill, etc) and stream data. Use this
    /// instead of a fixed-delay Task — CCCD refresh duration varies with
    /// BLE conditions.
    public typealias ReadyHandler = @Sendable () -> Void

    private let session: SensorSession
    // Held strongly so the underlying CBCentralManager survives past pairing.
    // SensorScanner owns the central manager + a [UUID: SensorSession] strong
    // map; dropping it tears the BLE connection down.
    private let scanner: SensorScanner
    private let crypto: DataPlaneCrypto
    private let decoder: DataPlaneDecoder
    private let assembler = DataPlaneNotificationAssembler()
    private let lock = NSLock()

    private var task: Task<Void, Never>?
    private var readingHandler: ReadingHandler?
    private var disconnectHandler: DisconnectHandler?
    private var statusHandler: StatusHandler?
    private var historicalPageHandler: HistoricalPageHandler?
    private var readyHandler: ReadyHandler?
    /// Per-session outbound write sequence counter, used for AES-CCM nonce
    /// construction on PatchControl writes.
    private var outboundSequence: UInt16 = 0

    init(scanner: SensorScanner, session: SensorSession, kEnc: Data, ivEnc: Data) throws {
        self.scanner = scanner
        self.session = session
        let crypto = try DataPlaneCrypto(kEnc: kEnc, ivEnc: ivEnc)
        self.crypto = crypto
        self.decoder = DataPlaneDecoder(crypto: crypto)
    }

    public func setHandlers(onReading: @escaping ReadingHandler,
                            onDisconnect: @escaping DisconnectHandler,
                            onStatus: @escaping StatusHandler = { _ in },
                            onHistoricalPage: @escaping HistoricalPageHandler = { _ in },
                            onReady: @escaping ReadyHandler = {}) {
        lock.lock()
        defer { lock.unlock() }
        self.readingHandler = onReading
        self.disconnectHandler = onDisconnect
        self.statusHandler = onStatus
        self.historicalPageHandler = onHistoricalPage
        self.readyHandler = onReady
    }

    private func emitStatus(_ text: String) {
        lock.lock()
        let h = statusHandler
        lock.unlock()
        h?(text)
    }

    public func start() {
        lock.lock()
        let alreadyRunning = task != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let newTask = Task { [weak self] in
            guard let self else { return }
            llog("monitor starting; refreshing post-auth notifications")
            self.emitStatus("Refreshing notifications")
            let refreshOK = await self.refreshPostAuthNotifications()
            // If CCCD refresh failed because the BLE link died between
            // handshake-complete and our first CCCD write, the session is
            // already dead. session.notifications() on a dead session
            // doesn't terminate in a useful timeframe — without this short-
            // circuit we'd sit silently in the consume loop indefinitely
            // (verified: 55-minute hang in field log after a 14:23 CCCD
            // failure that wasn't propagated). Fire disconnect immediately
            // so the CGMManager re-enters the reconnect loop.
            if !refreshOK {
                llog("CCCD refresh failed; treating session as disconnected and not consuming notifications")
                self.lock.lock()
                let handler = self.disconnectHandler
                self.lock.unlock()
                handler?()
                return
            }
            // Fire ready BEFORE consuming notifications so consumers (e.g.
            // backfill request) can race ahead of the first realtime packet
            // and not miss notifications. Both are on the same session queue
            // so order is preserved.
            self.lock.lock()
            let ready = self.readyHandler
            self.lock.unlock()
            ready?()
            llog("monitor consuming session.notifications()")
            self.emitStatus("Waiting for first reading")
            var eventCount = 0
            for await event in self.session.notifications() {
                eventCount += 1
                llog("notify #\(eventCount) char=\(event.characteristic.uuidString) len=\(event.fragment.count)")
                self.handle(event)
                if Task.isCancelled { break }
            }
            llog("monitor notification stream ended after \(eventCount) events; invoking disconnect handler")
            self.lock.lock()
            let handler = self.disconnectHandler
            self.lock.unlock()
            handler?()
        }
        lock.lock()
        task = newTask
        lock.unlock()
    }

    /// After Phase 6 the sensor's data-plane characteristics need a CCCD
    /// off→on cycle before the sensor will start streaming. Without this
    /// the BLE session stays open but no glucose notifications arrive, and
    /// eventually iOS or the sensor drops the link.
    ///
    /// Delegated to LibreCRKit's `SensorSession.refreshDataPlaneNotifications()`
    /// (added in the refresh-data-plane-notifications branch); LibreLoop
    /// previously implemented this inline.
    private func refreshPostAuthNotifications() async -> Bool {
        do {
            llog("CCCD refresh starting")
            try await session.refreshDataPlaneNotifications()
            llog("CCCD refresh complete")
            return true
        } catch {
            llog("CCCD refresh failed: \(String(describing: error))")
            return false
        }
    }

    /// Request the sensor stream all historical samples with
    /// `lifeCount >= fromLifeCount`. Responses arrive asynchronously on
    /// the historicData channel and are routed via `onHistoricalPage`.
    /// Sensor stops on its own when the range is exhausted; no terminator.
    public func requestHistoricalBackfill(fromLifeCount: UInt16) async throws {
        // Realtime monitoring doesn't need historicData subscribed, so the
        // default refreshDataPlaneNotifications list skips it. Backfill
        // responses are delivered on this channel though, so enable its CCCD
        // first or the writes go through but the pages never reach us.
        do {
            try await session.setNotify(true, for: LibreSensorGATT.Char.historicData, timeout: 5)
            llog("historicData notifications enabled for backfill")
        } catch {
            llog("failed to enable historicData notifications: \(String(describing: error))")
        }

        let command = PatchControlCommand.historicalBackfillGreaterEqual(lifeCount: fromLifeCount)
        lock.lock()
        outboundSequence &+= 1
        let sequence = outboundSequence
        lock.unlock()
        let frame = try crypto.encrypt(
            plaintext: command.plaintext,
            sequence: sequence,
            kind: .patchControlWrite
        )
        llog("backfill request seq=\(sequence) >= lifeCount \(fromLifeCount)")
        try await session.writeRaw(
            frame.raw,
            to: LibreSensorGATT.Char.patchControl,
            timeout: 5.0
        )
    }

    public func stop() {
        lock.lock()
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }

    private func handle(_ event: NotifyEvent) {
        guard let channel = DataPlaneChannel(uuidString: event.characteristic.uuidString) else {
            llog("notify on unmapped char \(event.characteristic.uuidString)")
            return
        }
        guard let fullFrame = assembler.feed(fragment: event.fragment, channel: channel) else {
            llog("\(channel.rawValue) partial fragment buffered, waiting for completion")
            return
        }
        do {
            let frame = try DataFrame.parse(fullFrame)
            let packet = try decoder.decrypt(frame: frame, channel: channel)
            switch packet.payload {
            case .historicalReadingPage(let page):
                llog("historical page startLC=\(page.startLifeCount) endLC=\(page.endLifeCount) samples=\(page.samples.count)")
                lock.lock()
                let handler = historicalPageHandler
                lock.unlock()
                handler?(page)
            case .realtimeGlucose(let reading):
                // Build a SensorLifecycle from the reading's own age counter so
                // the quality assessment can correctly attribute "not actionable"
                // to warmup when applicable (and report remaining warmup minutes).
                let lifecycle = SensorLifecycle(currentLifeCountMinutes: Int(reading.lifeCount))
                let assessment = reading.currentGlucoseQualityAssessment(lifecycle: lifecycle)
                if assessment.issues.isEmpty {
                    llog("glucose mgdl=\(reading.currentGlucoseMgDL.map(String.init) ?? "nil") lifeCount=\(reading.lifeCount) trend=\(String(describing: reading.trendKind))")
                } else {
                    let issueText = assessment.issues.map { String(describing: $0) }.joined(separator: ", ")
                    llog("glucose mgdl=\(reading.currentGlucoseMgDL.map(String.init) ?? "nil") lifeCount=\(reading.lifeCount) issues=[\(issueText)]")
                }
                if let sample = Self.makeSample(from: reading, assessment: assessment, receivedAt: event.receivedAt) {
                    lock.lock()
                    let handler = readingHandler
                    lock.unlock()
                    handler?(sample)
                }
            default:
                llog("\(channel.rawValue) packet kind=\(packet.kind.rawValue) (no sample)")
            }
        } catch {
            llog("\(channel.rawValue) decode failed: \(String(describing: error))")
        }
    }

    /// Make a sample whenever we get a numeric mg/dL value, regardless of
    /// the sensor's actionability/quality flags. The flags are propagated to
    /// the manager via `isActionable` (which decides whether to forward the
    /// sample to Loop) and `qualityIssue` (UI text). Lower layers still see
    /// the reading so the link is proven alive even during not-actionable
    /// windows.
    private static func makeSample(
        from reading: RealtimeGlucoseReading,
        assessment: Libre3GlucoseQualityAssessment,
        receivedAt: Date
    ) -> LibreLoopGlucoseSample? {
        guard let mgdl = reading.currentGlucoseMgDL else { return nil }
        return LibreLoopGlucoseSample(
            date: receivedAt,
            valueMgDL: Double(mgdl),
            trend: mapTrend(reading.trendKind),
            rateOfChangeMgDLPerMinute: reading.rateOfChangeMgDLPerMinute.map(Double.init),
            lifeCount: reading.lifeCount,
            sensorTemperatureRaw: reading.temperature,
            isActionable: assessment.isUsable,
            qualityIssue: describeIssues(assessment.issues)
        )
    }

    /// Pick the most user-relevant issue and render it as a short UI string.
    /// Warmup and expiration are the most actionable signals to a user; we
    /// surface those preferentially and fall back to a one-line summary of
    /// the rest.
    private static func describeIssues(_ issues: [Libre3GlucoseQualityIssue]) -> String? {
        guard !issues.isEmpty else { return nil }
        for issue in issues {
            switch issue {
            case .sensorWarmup(let remaining):
                return "Warming up — \(remaining) min remaining"
            case .sensorExpired:
                return "Sensor expired"
            default:
                continue
            }
        }
        // No warmup/expired; describe the first remaining issue compactly.
        switch issues[0] {
        case .currentGlucoseUnavailable:
            return "Glucose unavailable"
        case .currentDataQuality(let dq):
            return "Data quality: \(dq)"
        case .sensorCondition(let cond):
            return "Sensor condition: \(cond)"
        case .notActionable:
            return "Not actionable"
        default:
            return "Reading not actionable"
        }
    }

    private static func mapTrend(_ libre: Libre3Trend) -> LibreLoopGlucoseSample.Trend {
        switch libre {
        case .notDetermined: return .notDetermined
        case .fallingQuickly: return .fallingQuickly
        case .falling: return .falling
        case .stable: return .stable
        case .rising: return .rising
        case .risingQuickly: return .risingQuickly
        case .raw: return .notDetermined
        }
    }
}

extension LibreLoopSensorMonitor {
    /// Internal builder used by `LibreLoopPairingService`.
    static func make(scanner: SensorScanner, session: SensorSession, kEnc: Data, ivEnc: Data) throws -> LibreLoopSensorMonitor {
        try LibreLoopSensorMonitor(scanner: scanner, session: session, kEnc: kEnc, ivEnc: ivEnc)
    }
}
