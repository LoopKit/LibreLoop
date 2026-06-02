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
    public typealias ClinicalRecordHandler = @Sendable (ClinicalReadingRecord) -> Void
    /// Every realtime glucose packet carries a paired 5-min historical
    /// sample (lifeCount + mg/dL) that the sensor commits at the same
    /// time as the current-minute realtime value. Surfacing these
    /// continuously means the historical buffer self-fills at realtime
    /// cadence, so a later reconnect's dedicated history backfill only
    /// needs to cover the actual outage window — not the sensor's
    /// ~15-min commit lag on top.
    public typealias EmbeddedHistoricalHandler = @Sendable (UInt16, UInt16) -> Void
    /// Patch-status frames arrive on their own characteristic ~once per
    /// minute *independent of glucose data*. Field observation shows the
    /// sensor doesn't reliably broadcast on this channel during initial
    /// warmup -- it sends realtime-glucose frames with nil mgdl instead
    /// (see LifeCountHandler). Kept as a fallback if a sensor variant
    /// behaves differently.
    public typealias PatchStatusHandler = @Sendable (PatchStatus) -> Void
    /// Fires on every realtime-glucose frame, including warmup frames
    /// that carry no mgdl. We can't form a glucose sample yet (no value),
    /// but the lifeCount lets us back-derive activatedAt before warmup
    /// completes -- which is the only signal we get during the first
    /// hour of a fresh sensor's life.
    public typealias LifeCountHandler = @Sendable (UInt16) -> Void
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
    private var clinicalRecordHandler: ClinicalRecordHandler?
    private var embeddedHistoricalHandler: EmbeddedHistoricalHandler?
    private var patchStatusHandler: PatchStatusHandler?
    private var lifeCountHandler: LifeCountHandler?
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
                            onClinicalRecord: @escaping ClinicalRecordHandler = { _ in },
                            onEmbeddedHistorical: @escaping EmbeddedHistoricalHandler = { _, _ in },
                            onPatchStatus: @escaping PatchStatusHandler = { _ in },
                            onLifeCount: @escaping LifeCountHandler = { _ in },
                            onReady: @escaping ReadyHandler = {}) {
        lock.lock()
        defer { lock.unlock() }
        self.readingHandler = onReading
        self.disconnectHandler = onDisconnect
        self.statusHandler = onStatus
        self.historicalPageHandler = onHistoricalPage
        self.clinicalRecordHandler = onClinicalRecord
        self.embeddedHistoricalHandler = onEmbeddedHistorical
        self.patchStatusHandler = onPatchStatus
        self.lifeCountHandler = onLifeCount
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
        try await issueBackfill(stream: .historical, fromLifeCount: fromLifeCount)
    }

    /// Diagnostic: also ask the sensor for the clinical stream. Same decode
    /// shape as historical but delivered on `clinicalData`. LibreCRKit's
    /// protocol notes don't ground what's in it; we send the request,
    /// subscribe to the CCCD, and route the pages with `source: .clinical`
    /// so the manager can compare them against historical/realtime.
    public func requestClinicalBackfill(fromLifeCount: UInt16) async throws {
        try await issueBackfill(stream: .clinical, fromLifeCount: fromLifeCount)
    }

    private func issueBackfill(stream: BackfillStream, fromLifeCount: UInt16) async throws {
        // Realtime monitoring doesn't need historicData/clinicalData
        // subscribed, so the default refreshDataPlaneNotifications list
        // skips them. Enable the appropriate channel's CCCD here or the
        // writes go through but the pages never reach us.
        let chr: CBUUID
        let label: String
        switch stream {
        case .historical:
            chr = LibreSensorGATT.Char.historicData
            label = "historicData"
        case .clinical:
            chr = LibreSensorGATT.Char.clinicalData
            label = "clinicalData"
        }
        do {
            try await session.setNotify(true, for: chr, timeout: 5)
            llog("\(label) notifications enabled for backfill")
        } catch {
            llog("failed to enable \(label) notifications: \(String(describing: error))")
        }

        let command: PatchControlCommand
        switch stream {
        case .historical:
            command = PatchControlCommand.historicalBackfillGreaterEqual(lifeCount: fromLifeCount)
        case .clinical:
            command = PatchControlCommand.clinicalBackfillGreaterEqual(lifeCount: fromLifeCount)
        }
        lock.lock()
        outboundSequence &+= 1
        let sequence = outboundSequence
        lock.unlock()
        let frame = try crypto.encrypt(
            plaintext: command.plaintext,
            sequence: sequence,
            kind: .patchControlWrite
        )
        llog("\(label) backfill request seq=\(sequence) >= lifeCount \(fromLifeCount)")
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
            case .patchStatus(let status):
                // currentLifeCount is the sensor's age in minutes, broadcast
                // every minute on the patchStatus characteristic. Critical
                // during initial warmup, where the realtime glucose stream
                // is silent for ~60 min after activation -- without this
                // path activatedAt stays nil for the entire warmup window.
                llog("patch status currentLC=\(status.currentLifeCount) lifeCount=\(status.lifeCount) state=\(status.patchStateKind)")
                lock.lock()
                let handler = patchStatusHandler
                lock.unlock()
                handler?(status)
            case .historicalReadingPage(let page):
                llog("historical page startLC=\(page.startLifeCount) endLC=\(page.endLifeCount) samples=\(page.samples.count)")
                lock.lock()
                let handler = historicalPageHandler
                lock.unlock()
                handler?(page)
            case .clinicalReadingRecord(let record):
                let cur = record.currentGlucoseMgDL.map(String.init) ?? "nil"
                let sm = record.smoothedGlucoseMgDL.map(String.init) ?? "nil"
                llog("clinical record lifeCount=\(record.lifeCount) current=\(cur) mg/dL smoothed=\(sm) mg/dL @lifeCount=\(record.smoothedLifeCount)")
                lock.lock()
                let handler = clinicalRecordHandler
                lock.unlock()
                handler?(record)
            case .realtimeGlucose(let reading):
                // Build a SensorLifecycle from the reading's own age counter so
                // the quality assessment can correctly attribute "not actionable"
                // to warmup when applicable (and report remaining warmup minutes).
                let lifecycle = SensorLifecycle(currentLifeCountMinutes: Int(reading.lifeCount))
                let assessment = reading.currentGlucoseQualityAssessment(lifecycle: lifecycle)
                // Log trendAndStatusByte (byte 14 of the realtime frame)
                // alongside the decoded fields. LibreCRKit's live-capture
                // fixture shows 0x0b for a stable+actionable reading on
                // Libre 3 (trend=3 | bit3 actionable | rest=0). If we
                // see byte 14 with bit 3 clear but other upper bits set,
                // it would suggest a sensor variant has the flag in a
                // different position than the test data assumed.
                //
                // Also log the full 29-byte decrypted plaintext as hex --
                // dropped straight into RealtimeGlucoseReading(plaintext:)
                // it reproduces the exact frame for the LibreCRKit
                // developer to inspect.
                let byte14 = String(format: "0x%02x", reading.trendAndStatusByte)
                let plaintextHex = packet.plaintext.map { String(format: "%02x", $0) }.joined()
                if assessment.issues.isEmpty {
                    llog("glucose mgdl=\(reading.currentGlucoseMgDL.map(String.init) ?? "nil") lifeCount=\(reading.lifeCount) trend=\(String(describing: reading.trendKind)) byte14=\(byte14) rest=\(reading.rest) plaintext=\(plaintextHex)")
                } else {
                    let issueText = assessment.issues.map { String(describing: $0) }.joined(separator: ", ")
                    llog("glucose mgdl=\(reading.currentGlucoseMgDL.map(String.init) ?? "nil") lifeCount=\(reading.lifeCount) byte14=\(byte14) rest=\(reading.rest) issues=[\(issueText)] plaintext=\(plaintextHex)")
                }
                // Surface lifeCount unconditionally -- warmup readings have
                // valid lifeCount but nil mgdl, and that's still enough to
                // pin activatedAt.
                lock.lock()
                let lcHandler = lifeCountHandler
                lock.unlock()
                lcHandler?(reading.lifeCount)
                if let sample = Self.makeSample(from: reading, assessment: assessment, receivedAt: event.receivedAt) {
                    lock.lock()
                    let handler = readingHandler
                    lock.unlock()
                    handler?(sample)
                }
                // Surface the realtime packet's paired 5-min historical
                // sample. Sensor commits this at the same time as the
                // current-minute realtime value; harvesting it here is
                // what keeps the historical buffer aligned to "now" and
                // makes reconnect-time gap-fill mostly unnecessary.
                if reading.isHistoricalGlucoseValid,
                   let histMgDL = reading.historicalGlucoseMgDL,
                   reading.historicalLifeCount > 0 {
                    lock.lock()
                    let embedded = embeddedHistoricalHandler
                    lock.unlock()
                    embedded?(reading.historicalLifeCount, histMgDL)
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
        // mgdl from currentGlucoseMgDL is the *display* value: capped at
        // 39 / 501 when the sensor pegs out. We surface that censoring
        // via `condition` so downstream consumers (chart, NS upload) can
        // mark these distinctly from in-range readings.
        let condition: LibreLoopGlucoseSample.Condition?
        switch reading.currentGlucoseStatus {
        case .belowDisplayRange: condition = .belowRange
        case .aboveDisplayRange: condition = .aboveRange
        case .valid, .unavailable: condition = nil
        }
        // LibreCRKit 88508ae classified issues as advisory vs. usability-
        // blocking. `.notActionable` is advisory (Abbott's own app still
        // displays the value, the bit only drives an icon overlay); DQ
        // errors, sensor condition faults, expiry, warmup, and value-
        // unavailable are usability-blocking. We forward sample state
        // accordingly:
        //   isActionable = no issues at all (clean reading)
        //   hasBlockingIssue = sensor-reported fault, skip forwarding
        //   else (advisories only) = forward as isDisplayOnly
        let isActionable = assessment.issues.isEmpty
        let hasBlockingIssue = !assessment.blockingIssues.isEmpty
        return LibreLoopGlucoseSample(
            date: receivedAt,
            valueMgDL: Double(mgdl),
            trend: mapTrend(reading.trendKind),
            rateOfChangeMgDLPerMinute: reading.rateOfChangeMgDLPerMinute.map(Double.init),
            lifeCount: reading.lifeCount,
            sensorTemperatureRaw: reading.temperature,
            isActionable: isActionable,
            hasBlockingIssue: hasBlockingIssue,
            condition: condition,
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
        // Use Loop terminology ("Display only") for the actionability flag
        // since it maps directly to NewGlucoseSample.isDisplayOnly on the
        // forwarded sample.
        switch issues[0] {
        case .currentGlucoseUnavailable:
            return "Glucose unavailable"
        case .currentDataQuality(let dq):
            return "Data quality: \(dq)"
        case .sensorCondition(let cond):
            return "Sensor condition: \(cond)"
        case .notActionable:
            return "Display only"
        default:
            return "Display only"
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
