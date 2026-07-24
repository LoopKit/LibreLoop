import Foundation
import CoreBluetooth
import LibreCRKit
import os.log


/// Developer-facing runtime flags persisted in UserDefaults.
public enum LibreLoopDebugSettings {
    /// Keep the clinical channel CCCD subscribed for the whole session so the
    /// Glucose Streams debug view's clinical/raw charts update live. OFF by
    /// default — it adds per-reconnect clinical churn and is only needed for
    /// stream inspection; normal operation uses realtime + on-reconnect
    /// clinical backfill.
    public static let continuousClinicalKey = "org.loopkit.LibreLoop.continuousClinical"
    public static var continuousClinicalEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: continuousClinicalKey) }
        set { UserDefaults.standard.set(newValue, forKey: continuousClinicalKey) }
    }
}


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
    public typealias RawReadHandler = @Sendable (LibreLoopStreamReadRecord) -> Void

    private let session: SensorSession
    // Held strongly so the underlying CBCentralManager survives past pairing.
    // SensorScannerNG owns the central manager + a [UUID: SensorSession] strong
    // map; dropping it tears the BLE connection down.
    private let scanner: SensorScannerNG
    private let crypto: DataPlaneCrypto
    private let decoder: DataPlaneDecoder
    private let assembler = DataPlaneNotificationAssembler()
    private let lock = NSLock()

    private var task: Task<Void, Never>?
    /// Per-channel data-plane silence watchdog: re-arms only the specific channel
    /// that goes quiet, instead of blanket-toggling every CCCD on reconnect.
    private var silenceWatchdog: Task<Void, Never>?
    /// Last time a patchStatus frame arrived (notify or read-fallback).
    private var lastPatchStatusAt: Date?
    /// Last time a glucose frame arrived.
    private var lastGlucoseAt: Date?
    /// Stuck-value detector state: the last raw current-glucose word, the
    /// lifeCount it arrived at, and the count of consecutive *advancing* frames
    /// that repeated it. Catches a held/frozen glucose (e.g. after a DQ error) —
    /// the repeats carry no error flag, so they look valid and get forwarded.
    private var lastGlucoseWord: UInt16?
    private var lastGlucoseWordLifeCount: UInt16?
    private var stuckGlucoseRun: Int = 0
    private var readingHandler: ReadingHandler?
    private var disconnectHandler: DisconnectHandler?
    private var statusHandler: StatusHandler?
    private var historicalPageHandler: HistoricalPageHandler?
    private var clinicalRecordHandler: ClinicalRecordHandler?
    private var embeddedHistoricalHandler: EmbeddedHistoricalHandler?
    private var patchStatusHandler: PatchStatusHandler?
    private var lifeCountHandler: LifeCountHandler?
    private var readyHandler: ReadyHandler?
    private var rawReadHandler: RawReadHandler?
    /// Monotonic id for captured read records (debug inspector).
    private var readSequence = 0
    /// Per-session outbound write sequence counter, used for AES-CCM nonce
    /// construction on PatchControl writes.
    private var outboundSequence: UInt16 = 0

    init(scanner: SensorScannerNG, session: SensorSession, kEnc: Data, ivEnc: Data) throws {
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
                            onReady: @escaping ReadyHandler = {},
                            onRawRead: @escaping RawReadHandler = { _ in }) {
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
        self.rawReadHandler = onRawRead
    }

    /// Build + emit a captured read record (debug inspector). Thread-safe.
    private func emitRead(_ channel: String, summary: String, at receivedAt: Date,
                          _ properties: [(String, String)]) {
        lock.lock()
        readSequence += 1
        let seq = readSequence
        let handler = rawReadHandler
        lock.unlock()
        guard let handler else { return }
        handler(LibreLoopStreamReadRecord(id: seq, receivedAt: receivedAt, channel: channel,
                                          summary: summary, properties: properties))
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
                llog("CCCD refresh failed; closing the link so the reconnect is a fresh connect + full re-subscribe")
                // We never finished setup (post-auth CCCD arm), so don't sit on the
                // still-open link -- close it. Reusing a half-set-up connection
                // re-arms cached, un-acked CCCD state and relivelocks
                // (connect→adopt→arm-fail, repeat); a fresh connect forces a full
                // re-discover + re-arm -- the "clears only on a fresh characteristic
                // discovery" the livelock note describes, without an app restart.
                // Critically, a half-set-up link can stay connected while the
                // regular-data channels (glucose/patchStatus) never armed, so iOS
                // gets no notification to wake us on: closing avoids that dead state.
                self.scanner.cancelConnection(self.session.peripheral)
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
            self.startSilenceWatchdog()
            var eventCount = 0
            for await event in self.session.notifications() {
                eventCount += 1
                llog("notify #\(eventCount) char=\(event.characteristic.uuidString) len=\(event.fragment.count)")
                self.handle(event)
                if Task.isCancelled { break }
            }
            self.stopSilenceWatchdog()
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

    /// Per-channel data-plane silence watchdog. Instead of blanket-toggling every
    /// CCCD on each reconnect (churn that briefly interrupts healthy channels), we
    /// arm minimally on connect and recover a *specific* channel only once it has
    /// actually gone quiet:
    ///  - patchStatus quiet ≥60s → a direct `readPatchStatus()` (no CCCD churn;
    ///    the result returns via `notifications()` and is handled like any
    ///    patchStatus frame, keeping `activatedAt`/lifecycle flowing). Still quiet
    ///    ≥150s → a targeted off→on CCCD re-arm of patchStatus.
    ///  - glucose quiet ≥150s (≈2+ missed ~1-min frames) → a targeted off→on
    ///    re-arm of glucoseData (glucose has no read fallback).
    /// Vendor parity: Abbott's app reads patchStatus when the notify stream goes
    /// quiet. Churn is spent only on a channel proven un-armed.
    private func startSilenceWatchdog() {
        lock.lock()
        let now = Date()
        lastPatchStatusAt = now   // grace from the start of consumption
        lastGlucoseAt = now
        silenceWatchdog?.cancel()
        let wd = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)   // check every 20s
                guard let self, !Task.isCancelled else { return }
                self.lock.lock()
                let psLast = self.lastPatchStatusAt
                let glLast = self.lastGlucoseAt
                self.lock.unlock()
                let t = Date()
                let psQuiet = psLast.map { t.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                let glQuiet = glLast.map { t.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

                if psQuiet >= 60 {
                    if psQuiet >= 150 {
                        llog("patchStatus quiet \(Int(psQuiet))s; targeted CCCD re-arm")
                        try? await self.session.refreshDataPlaneNotifications(
                            characteristics: [LibreSensorGATT.Char.patchStatus],
                            forceReArm: [LibreSensorGATT.Char.patchStatus]
                        )
                    }
                    llog("patchStatus quiet \(Int(psQuiet))s; issuing direct read (vendor-parity fallback)")
                    do {
                        _ = try await self.session.readPatchStatus()
                    } catch {
                        llog("readPatchStatus failed: \(String(describing: error))")
                    }
                    // Bump so we don't re-issue every tick while awaiting the
                    // result; a real patchStatus frame (read or notify) resets it.
                    self.lock.lock()
                    self.lastPatchStatusAt = Date()
                    self.lock.unlock()
                }

                if glQuiet >= 150 {
                    llog("glucose quiet \(Int(glQuiet))s; targeted CCCD re-arm")
                    try? await self.session.refreshDataPlaneNotifications(
                        characteristics: [LibreSensorGATT.Char.glucoseData],
                        forceReArm: [LibreSensorGATT.Char.glucoseData]
                    )
                    self.lock.lock()
                    self.lastGlucoseAt = Date()
                    self.lock.unlock()
                }
            }
        }
        silenceWatchdog = wd
        lock.unlock()
    }

    private func stopSilenceWatchdog() {
        lock.lock()
        let wd = silenceWatchdog
        silenceWatchdog = nil
        lock.unlock()
        wd?.cancel()
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
            // Reproduce the 2026-05-06 working-backfill post-handshake state:
            // force off→on on the FULL data-plane response set, INCLUDING
            // historicData + clinicalData. The sensor appears to inspect the CCCD
            // state of all data-plane response channels before accepting a
            // patchControl command — an un-armed one yields ATT 0xFD ("CCCD
            // improperly configured") on the backfill write. The current failing
            // captures never armed historicData/clinicalData (they're not in
            // dataPlaneNotifying); the 05-06 working trace did.
            //
            // This arms DESCRIPTORS only; it does NOT widen how much clinical/
            // historical we forward to Loop — clinical backfill stays windowed
            // (recentClinicalWindow), so the historical-drain mitigation holds.
            // Arming historicData may trigger an automatic post-auth historical
            // burst; that's backfill data we want and it's deduped by
            // backfillForwardedLifeCounts. This is a one-time post-handshake cost
            // (not the per-retry churn that was backed out); it also restores a
            // real CCCD write to patchStatus/glucose that forceReArm:[] had left
            // to a retention short-circuit.
            let backfillReadyChars: [CBUUID] = LibreSensorGATT.Char.dataPlaneNotifying + [
                LibreSensorGATT.Char.historicData,
                LibreSensorGATT.Char.clinicalData,
            ]
            try await session.refreshDataPlaneNotifications(
                characteristics: backfillReadyChars,
                forceReArm: Set(backfillReadyChars)
            )
            llog("CCCD refresh complete (05-06 backfill-ready set: +historicData +clinicalData)")
            // Optionally keep the clinical channel subscribed for the whole
            // session so the Streams debug view's clinical/raw charts update
            // live. OFF by default (it adds per-reconnect clinical churn and is
            // only needed for stream inspection). Best-effort either way.
            if LibreLoopDebugSettings.continuousClinicalEnabled {
                do {
                    try await session.setNotify(true, for: LibreSensorGATT.Char.clinicalData, timeout: 5)
                    llog("clinicalData notifications enabled (continuous)")
                } catch {
                    llog("continuous clinicalData enable failed: \(String(describing: error))")
                }
            }
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
            // Enable the response channel so backfill pages can stream in. NOTE:
            // a forced off→on re-arm of this channel + patchControl was tried to
            // clear the sensor's ATT 0xFD ("CCCD Improperly Configured") rejection
            // of the command write and did NOT help — 0xFD persists with both
            // CCCDs freshly written. So 0xFD is an application-level rejection
            // (likely command sequence/nonce or state), not a literal CCCD issue;
            // re-arming here only churns CCCDs every retry. Plain enable only.
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
        let wd = silenceWatchdog
        silenceWatchdog = nil
        lock.unlock()
        t?.cancel()
        wd?.cancel()
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
                lastPatchStatusAt = event.receivedAt   // feed the read-fallback watchdog
                lock.unlock()
                handler?(status)
                emitRead("Patch status", summary: "LC \(status.currentLifeCount) \(status.patchStateKind)", at: event.receivedAt, [
                    ("currentLifeCount", "\(status.currentLifeCount)"),
                    ("lifeCount", "\(status.lifeCount)"),
                    ("state", "\(status.patchStateKind)"),
                    ("errorData", "\(status.errorData)"),
                    ("eventData", "\(status.eventData)"),
                    ("index/total", "\(status.index)/\(status.totalEvents)"),
                    ("stackDisconnectReason", "\(status.stackDisconnectReason)"),
                    ("appDisconnectReason", "\(status.appDisconnectReason)"),
                ])
            case .historicalReadingPage(let page):
                llog("historical page startLC=\(page.startLifeCount) endLC=\(page.endLifeCount) samples=\(page.samples.count)")
                lock.lock()
                let handler = historicalPageHandler
                lock.unlock()
                handler?(page)
                var pageProps: [(String, String)] = [
                    ("startLifeCount", "\(page.startLifeCount)"),
                    ("endLifeCount", "\(page.endLifeCount)"),
                    ("sampleCount", "\(page.samples.count)"),
                ]
                for s in page.samples {
                    pageProps.append(("LC \(s.lifeCount)", s.glucoseMgDL.map { "\($0) mg/dL" } ?? "raw \(s.rawValue)"))
                }
                emitRead("Historic page", summary: "\(page.startLifeCount)–\(page.endLifeCount) (\(page.samples.count))", at: event.receivedAt, pageProps)
            case .clinicalReadingRecord(let record):
                let cur = record.currentGlucoseMgDL.map(String.init) ?? "nil"
                let hist = record.historicGlucoseMgDL.map(String.init) ?? "nil"
                llog("clinical record lifeCount=\(record.lifeCount) current=\(cur) mg/dL historicRaw=\(hist) mg/dL")
                lock.lock()
                let handler = clinicalRecordHandler
                lock.unlock()
                handler?(record)
                emitRead("Clinical", summary: "LC \(record.lifeCount) cur \(cur)", at: event.receivedAt, [
                    ("lifeCount", "\(record.lifeCount)"),
                    ("currentGlucose", record.currentGlucoseMgDL.map { "\($0) mg/dL" } ?? "—"),
                    ("currentGlucoseRaw (word5)", "\(record.currentGlucoseRaw)"),
                    ("historicGlucose", record.historicGlucoseMgDL.map { "\($0) mg/dL" } ?? "—"),
                    ("historicGlucoseRaw (word6)", "\(record.historicGlucoseRaw)"),
                    ("historicLifeCountEst", record.historicLifeCountEstimate.map(String.init) ?? "—"),
                    ("rawSensorWord1", "\(record.rawSensorWord1)"),
                    ("rawSensorWord2", "\(record.rawSensorWord2)"),
                    ("rawSensorWord3", "\(record.rawSensorWord3)"),
                    ("reservedWord", "\(record.reservedWord)"),
                ])
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
                // Surface the decoded data-quality evidence on every frame: the
                // raw current-glucose word (the field that froze in the stuck-53
                // case), the DQ error (0x8000 family), sensor condition, and
                // actionability. Previously these were only visible when they
                // escalated to a blocking issue — but a held value reports clean.
                let mgdlStr = reading.currentGlucoseMgDL.map(String.init) ?? "nil"
                let word = String(format: "0x%04x", reading.currentWord)
                let dqInfo = "word=\(word) dq=\(reading.dqError) cond=\(reading.sensorCondition) act=\(reading.actionability)"
                if assessment.issues.isEmpty {
                    llog("glucose mgdl=\(mgdlStr) lifeCount=\(reading.lifeCount) trend=\(String(describing: reading.trendKind)) byte14=\(byte14) rest=\(reading.rest) \(dqInfo) plaintext=\(plaintextHex)")
                } else {
                    let issueText = assessment.issues.map { String(describing: $0) }.joined(separator: ", ")
                    llog("glucose mgdl=\(mgdlStr) lifeCount=\(reading.lifeCount) byte14=\(byte14) rest=\(reading.rest) \(dqInfo) issues=[\(issueText)] plaintext=\(plaintextHex)")
                }
                // Surface lifeCount unconditionally -- warmup readings have
                // valid lifeCount but nil mgdl, and that's still enough to
                // pin activatedAt.
                lock.lock()
                let lcHandler = lifeCountHandler
                lastGlucoseAt = event.receivedAt   // feed the silence watchdog
                // Stuck-value detector: count consecutive *advancing* frames that
                // repeat the raw current-glucose word. A same-minute resend
                // (lifeCount unchanged) doesn't count; a new lifeCount carrying
                // an identical word is a held/frozen value.
                if reading.lifeCount == lastGlucoseWordLifeCount {
                    // same-minute resend — ignore for the stuck run
                } else if lastGlucoseWord == reading.currentWord {
                    stuckGlucoseRun += 1
                } else {
                    stuckGlucoseRun = 0
                }
                lastGlucoseWord = reading.currentWord
                lastGlucoseWordLifeCount = reading.lifeCount
                let stuckRun = stuckGlucoseRun
                lock.unlock()
                if stuckRun >= 3 {
                    llog("STUCK: current glucose word \(String(format: "0x%04x", reading.currentWord)) unchanged across \(stuckRun + 1) advancing frames (lifeCount=\(reading.lifeCount) mgdl=\(mgdlStr) dq=\(reading.dqError))")
                }
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
                let histLag = Int(reading.lifeCount) - Int(reading.historicalLifeCount)
                emitRead("Realtime", summary: "\(reading.currentGlucoseMgDL.map(String.init) ?? "—") mg/dL  LC \(reading.lifeCount)", at: event.receivedAt, [
                    ("currentGlucose", reading.currentGlucoseMgDL.map { "\($0) mg/dL" } ?? "—"),
                    ("currentValid", "\(reading.isCurrentGlucoseValid)"),
                    ("uncappedCurrent", "\(reading.uncappedCurrentMgDL)"),
                    ("lifeCount", "\(reading.lifeCount)"),
                    ("trend", "\(reading.trendKind) (raw \(reading.trendRaw))"),
                    ("rateOfChange", reading.rateOfChangeMgDLPerMinute.map { String(format: "%+.2f mg/dL/min", $0) } ?? "—"),
                    ("projectedGlucose", "\(reading.projectedGlucose)"),
                    ("temperature", "\(reading.temperature) (status \(reading.temperatureStatus))"),
                    ("dqError", "\(reading.dqError)"),
                    ("sensorCondition", "\(reading.sensorCondition)"),
                    ("actionability", "\(reading.actionability)"),
                    ("esaDuration", "\(reading.esaDuration)"),
                    ("historicalLifeCount", "\(reading.historicalLifeCount)"),
                    ("historical lag (min)", "\(histLag)"),
                    ("historicalGlucose", reading.historicalGlucoseMgDL.map { "\($0) mg/dL" } ?? "—"),
                    ("historicalValid", "\(reading.isHistoricalGlucoseValid)"),
                    ("uncappedHistoric", "\(reading.uncappedHistoricMgDL)"),
                    ("historicRangeStatus", "\(reading.historicResultRangeStatus)"),
                    ("trendAndStatusByte", byte14),
                    ("rest", "\(reading.rest)"),
                    ("wordsLE", reading.wordsLE.map { String(format: "%04x", $0) }.joined(separator: " ")),
                    ("plaintext", plaintextHex),
                ])
            default:
                llog("\(channel.rawValue) packet kind=\(packet.kind.rawValue) (no sample)")
                emitRead(channel.rawValue, summary: "kind \(packet.kind.rawValue) (no sample)", at: event.receivedAt, [
                    ("kind", "\(packet.kind.rawValue)"),
                    ("plaintext", packet.plaintext.map { String(format: "%02x", $0) }.joined()),
                ])
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
    static func make(scanner: SensorScannerNG, session: SensorSession, kEnc: Data, ivEnc: Data) throws -> LibreLoopSensorMonitor {
        try LibreLoopSensorMonitor(scanner: scanner, session: session, kEnc: kEnc, ivEnc: ivEnc)
    }
}
