import Foundation
import HealthKit
import LibreCRKit
import LoopAlgorithm
import LoopKit
import os.log


extension LibreLoopCGMManager {
    static func receiverIDFromState(_ data: Data?) -> UInt32? {
        guard let data, data.count == 4 else { return nil }
        return UInt32(data[0])
            | (UInt32(data[1]) << 8)
            | (UInt32(data[2]) << 16)
            | (UInt32(data[3]) << 24)
    }

    /// Saves the NFC half of pairing the instant it completes successfully,
    /// before any BLE work. Per LibreCRKit author guidance: a successful A8
    /// burns the previous BLE PIN and issues a new one in the response, so
    /// the new PIN MUST be persisted before we touch BLE -- a crash or
    /// handshake failure must not leave the sensor stranded.
    public func applyNFCResponse(_ response: LibreLoopPairingService.NFCResponse) {
        llog("NFC response applied: serial=\(response.sensorSerial) bleAddress=\(response.bleAddress ?? "nil") blePIN bytes=\(response.blePIN.count)")
        cancelReconnect()
        var newState = state
        newState.receiverID = withUnsafeBytes(of: response.receiverID.littleEndian) { Data($0) }
        newState.sensorSerial = response.sensorSerial
        newState.bleAddress = response.bleAddress
        newState.blePIN = response.blePIN
        newState.activatedAt = response.activatedAt
        setState(newState)
    }

    /// Completes pairing after BLE handshake succeeds: persists session keys
    /// to Keychain and adopts the live monitor. NFC fields are already in
    /// state by this point (see applyNFCResponse).
    public func applyPairingOutcome(_ outcome: LibreLoopPairingService.PairOutcome) throws {
        llog("pairing outcome applied: serial=\(outcome.result.sensorSerial) peripheral=\(outcome.peripheralID.uuidString); adopting monitor")
        try LibreLoopKeychain.save(
            LibreLoopKeychain.SessionKeys(
                kEnc: outcome.result.kEnc,
                ivEnc: outcome.result.ivEnc,
                phase5RawKey: outcome.result.phase5RawKey,
                receiverID: Self.receiverIDFromState(state.receiverID)
            ),
            forSensorSerial: outcome.result.sensorSerial
        )

        var newState = state
        newState.peripheralID = outcome.peripheralID
        newState.lastPairedAt = Date()
        // Switch-receiver re-arms sensor stabilization; clear the prior
        // actionable timestamp so the lifecycle bar correctly reports
        // "Warming up" until the new pairing produces an actionable reading.
        newState.firstActionableReadingAt = nil
        setState(newState)

        adopt(monitor: outcome.monitor)
    }

    func adopt(monitor: LibreLoopSensorMonitor) {
        self.monitor = monitor
        // Each new BLE session gets its own backfill window.
        self.hasRequestedBackfillThisSession = false
        self.backfillForwardedLifeCounts.removeAll(keepingCapacity: true)
        self.lastHistoricalPageAt = nil
        monitor.setHandlers(
            onReading: { [weak self] sample in self?.ingest(sample) },
            onDisconnect: { [weak self] in self?.handleMonitorDisconnect() },
            onStatus: { [weak self] text in self?.updateStatusDetail(text) },
            onHistoricalPage: { [weak self] page in self?.handleHistoricalPage(page) },
            onClinicalRecord: { [weak self] record in self?.handleClinicalRecord(record) }
        )
        monitor.start()
        // Start the no-data watchdog immediately after adoption -- if the
        // first reading doesn't arrive within the threshold, the link is
        // probably silently dead and a reconnect is in order.
        startNoDataWatchdog()
    }

    /// Compute the lifecount to start backfill from for the current session.
    /// Mirrors the upstream PoC's `historyBackfillStart`: if we have a saved
    /// watermark, request that minus a 10-count overlap (avoids gaps on
    /// either side of the reconnect boundary); otherwise look back 180
    /// lifecounts (~15 hours) from the current realtime reading.
    ///
    /// We never send `lifeCount = 0` — empirically the sensor silently
    /// ignores "give me everything" requests; it wants a bounded range.
    private func backfillStartLifeCount(currentLifeCount: UInt16) -> UInt16 {
        if let saved = state.lastHistoricalLifeCount {
            let overlap: UInt16 = 10
            return saved > overlap ? saved &- overlap : 5
        }
        let lookback: UInt16 = 180
        return currentLifeCount > lookback ? currentLifeCount &- lookback : 5
    }

    /// Trigger a backfill request once per BLE session, anchored to a real
    /// realtime reading's lifecount. Called from `ingest`. Subsequent
    /// realtime readings during the same session are no-ops.
    func requestBackfillIfNeeded(currentLifeCount: UInt16) {
        guard !hasRequestedBackfillThisSession else { return }
        guard let monitor else { return }
        hasRequestedBackfillThisSession = true
        let from = backfillStartLifeCount(currentLifeCount: currentLifeCount)
        Task { [weak self, weak monitor] in
            guard let monitor else { return }
            do {
                try await monitor.requestHistoricalBackfill(fromLifeCount: from)
            } catch {
                guard let self else { return }
                llog("backfill request failed: \(String(describing: error))")
                self.hasRequestedBackfillThisSession = false   // retry on next reading
                return
            }
            // Wait for the historical stream to drain before issuing the
            // clinical request. The sensor's patchControl write rejects a
            // second command while it's still responding to the first —
            // observed in the field as `writeFailed("Unknown ATT error")`
            // when clinical went out 0.4s after historical pages were
            // still arriving. Poll until we've seen no historical page
            // for `idleThreshold`, capped at `maxWait`.
            guard let self else { return }
            let idleThreshold: TimeInterval = 1.5
            let maxWait: TimeInterval = 15
            let waitStart = Date()
            while Date().timeIntervalSince(waitStart) < maxWait {
                let last = self.lastHistoricalPageAt
                let sinceLast = last.map { Date().timeIntervalSince($0) } ?? .infinity
                if sinceLast >= idleThreshold { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // Retry clinical with simple backoff. ATT errors right after
            // historical drain are usually transient (sensor still
            // settling); a couple of seconds between attempts clears them.
            let backoffs: [TimeInterval] = [0, 2, 4]
            for (i, delay) in backoffs.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                do {
                    try await monitor.requestClinicalBackfill(fromLifeCount: from)
                    return
                } catch {
                    let isLast = (i == backoffs.count - 1)
                    let prefix = isLast ? "clinical backfill failed after \(i + 1) attempts" : "clinical backfill attempt \(i + 1) failed, will retry"
                    llog("\(prefix): \(String(describing: error))")
                }
            }
        }
    }

    func ingest(_ sample: LibreLoopGlucoseSample) {
        recordSample(sample)
        // Restart the watchdog after every reading so it always reflects the
        // most recent silence window. Previously we only cancelled it on the
        // first reading, which meant a silent-disconnect (BLE link "open"
        // but no data flowing) had nothing watching for it after that point.
        startNoDataWatchdog()

        // Now that we have a confirmed realtime reading, we know the
        // sensor's current lifecount and can issue a sensible-range backfill
        // request (lifecount=0 is silently ignored by the sensor).
        requestBackfillIfNeeded(currentLifeCount: sample.lifeCount)

        var updated = state
        updated.latestReadingTimestamp = sample.date
        // Back-derive activation timestamp from the sensor's own age counter
        // (lifeCount, minutes since activation). Only set it once -- later
        // readings shouldn't shift it (small drift would otherwise jitter the
        // lifecycle bar).
        if updated.activatedAt == nil {
            updated.activatedAt = sample.date.addingTimeInterval(-TimeInterval(sample.lifeCount) * 60)
        }
        // First time the sensor flags a reading actionable post-pair tells
        // us warmup is done. Pin it so the lifecycle bar can leave warmup.
        if sample.isActionable, updated.firstActionableReadingAt == nil {
            updated.firstActionableReadingAt = sample.date
        }
        setState(updated)

        notifyStateObservers()

        // Status detail moves out of "Waiting for first reading" the instant
        // any reading arrives, even unactionable ones -- the link is proven.
        if !sample.isActionable {
            updateStatusDetail("Reading received (not actionable)")
            llog("ingested non-actionable sample (\(Int(sample.valueMgDL)) mg/dL); not forwarding to Loop")
            return
        }
        updateStatusDetail(nil)

        // Default-mode throttle: Loop's algorithm is paced around the
        // 5-minute CGM cadence other plugins emit, and per-minute updates
        // can shift dosing decisions in ways the cadence wasn't tuned for.
        // Only forward when at least 4.5 minutes (a 30-second slop under
        // 5 min, so the natural 5-min wall-clock cadence isn't blocked by
        // jitter) have passed since the last forwarded sample. Opt-out is
        // experimentalMinuteByMinuteForwarding, gated behind a warning UI.
        if !state.experimentalMinuteByMinuteForwarding,
           let last = state.latestForwardedToLoopAt,
           sample.date.timeIntervalSince(last) < 270 {
            let age = Int(sample.date.timeIntervalSince(last))
            llog("throttled: \(Int(sample.valueMgDL)) mg/dL lifeCount=\(sample.lifeCount) (only \(age)s since last forward; experimental minute-by-minute mode is off)")
            return
        }

        let newSample = NewGlucoseSample(
            date: sample.date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
            condition: nil,
            trend: Self.mapTrend(sample.trend),
            trendRate: sample.rateOfChangeMgDLPerMinute.map {
                LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "libreloop-\(state.sensorSerial ?? "unknown")-\(sample.lifeCount)",
            syncVersion: 1,
            device: device
        )

        llog("forwarding to Loop: \(Int(sample.valueMgDL)) mg/dL lifeCount=\(sample.lifeCount) sampleDate=\(sample.date.timeIntervalSince1970)")
        var stamped = state
        stamped.latestForwardedToLoopAt = sample.date
        setState(stamped)

        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData([newSample]))
        }
    }

    /// Delay between reconnect attempts. The first attempt after a disconnect
    /// uses this delay to let the BLE stack finish tearing down the dead link
    /// (avoids racing the disconnect cleanup). Subsequent attempts after a
    /// failed attempt also wait this long before retrying. CoreBluetooth's
    /// scan keeps the radio efficient under the hood, so a constant interval
    /// here doesn't need backoff.
    private static let reconnectDelay: TimeInterval = 2

    private static var reconnectTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Convert each historical sample into a NewGlucoseSample (when the page
    /// decoded mg/dL is present), push the batch to Loop's delegate, and
    /// advance `state.lastHistoricalLifeCount` so the next backfill picks
    /// up where we left off.
    func handleHistoricalPage(_ page: HistoricalReadingPage) {
        // Stamp this BEFORE the early-return guard — even pages we can't
        // forward yet count as the sensor still streaming to us. Used by
        // the post-historical clinical-request scheduler to detect when
        // the historical stream has drained.
        lastHistoricalPageAt = Date()
        guard let activatedAt = state.activatedAt else {
            llog("backfill page received before activatedAt known; deferring")
            return
        }
        let serial = state.sensorSerial ?? "unknown"
        let sourceLabel = "historical"
        // Dedup is two-layered: against realtime (live BLE stream we already
        // forwarded) and against this session's prior backfill forwards
        // (historical and clinical can overlap, and they may not even agree
        // on values for the same lifeCount since they're different sensor
        // pipelines).
        let realtimeLifeCounts = Set(recentSamples.map { $0.lifeCount })
        var newSamples: [NewGlucoseSample] = []
        var droppedRealtimeDup = 0
        var droppedBackfillDup = 0
        for sample in page.samples {
            guard let mgdl = sample.glucoseMgDL else { continue }
            if realtimeLifeCounts.contains(sample.lifeCount) {
                droppedRealtimeDup += 1
                continue
            }
            if backfillForwardedLifeCounts.contains(sample.lifeCount) {
                droppedBackfillDup += 1
                continue
            }
            let date = activatedAt.addingTimeInterval(TimeInterval(sample.lifeCount) * 60)
            newSamples.append(NewGlucoseSample(
                date: date,
                quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(mgdl)),
                condition: nil,
                trend: nil,
                trendRate: nil,
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: "libreloop-bkfill-\(serial)-\(sample.lifeCount)",
                syncVersion: 1,
                device: device
            ))
            backfillForwardedLifeCounts.insert(sample.lifeCount)
        }
        if !newSamples.isEmpty {
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData(newSamples))
            }
            let firstDate = newSamples.first?.date.timeIntervalSince1970 ?? 0
            let lastDate = newSamples.last?.date.timeIntervalSince1970 ?? 0
            let values = newSamples.map { Int($0.quantity.doubleValue(for: .milligramsPerDeciliter)) }
            var suffixParts: [String] = []
            if droppedRealtimeDup > 0 { suffixParts.append("\(droppedRealtimeDup) realtime-dup") }
            if droppedBackfillDup > 0 { suffixParts.append("\(droppedBackfillDup) backfill-dup") }
            let suffix = suffixParts.isEmpty ? "" : " (dropped \(suffixParts.joined(separator: ", ")))"
            llog("forwarded \(newSamples.count) \(sourceLabel) backfill samples to Loop: lifeCount \(page.startLifeCount)..\(page.endLifeCount), dates \(firstDate)..\(lastDate), mgdl=\(values)\(suffix)")
        } else if droppedRealtimeDup + droppedBackfillDup > 0 {
            llog("dropped all \(droppedRealtimeDup + droppedBackfillDup) \(sourceLabel) backfill sample(s) in page lifeCount \(page.startLifeCount)..\(page.endLifeCount) (realtime-dup=\(droppedRealtimeDup), backfill-dup=\(droppedBackfillDup))")
        }
        // Advance the historical watermark. Clinical pages early-returned
        // above and never reach this point.
        var updated = state
        let prior = updated.lastHistoricalLifeCount ?? 0
        if page.endLifeCount > prior {
            updated.lastHistoricalLifeCount = page.endLifeCount
            setState(updated)
        }
    }

    /// Forward a single per-minute glucose sample from a clinical-stream
    /// record. The historical stream only persists 5-min boundary samples
    /// so it can't fill the per-minute gaps left by a disconnect; clinical
    /// records carry the current-minute reading at `record.lifeCount`,
    /// which is exactly the granularity we want for gap-fill. Dedup is
    /// the same two-layered check used for historical: skip if we already
    /// have realtime or earlier-this-session backfill for that lifeCount.
    func handleClinicalRecord(_ record: ClinicalReadingRecord) {
        guard let activatedAt = state.activatedAt else {
            llog("clinical record received before activatedAt known; deferring")
            return
        }
        guard let mgdl = record.currentGlucoseMgDL else { return }
        let serial = state.sensorSerial ?? "unknown"

        let realtimeLifeCounts = Set(recentSamples.map { $0.lifeCount })
        if realtimeLifeCounts.contains(record.lifeCount) {
            llog("clinical record at lifeCount=\(record.lifeCount) dropped: realtime-dup")
            return
        }
        if backfillForwardedLifeCounts.contains(record.lifeCount) {
            llog("clinical record at lifeCount=\(record.lifeCount) dropped: backfill-dup")
            return
        }

        let date = activatedAt.addingTimeInterval(TimeInterval(record.lifeCount) * 60)
        let sample = NewGlucoseSample(
            date: date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(mgdl)),
            condition: nil,
            trend: nil,
            trendRate: nil,
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "libreloop-bkfill-\(serial)-\(record.lifeCount)",
            syncVersion: 1,
            device: device
        )
        backfillForwardedLifeCounts.insert(record.lifeCount)
        llog("forwarded clinical sample to Loop: \(mgdl) mg/dL lifeCount=\(record.lifeCount) sampleDate=\(date.timeIntervalSince1970)")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData([sample]))
        }
    }

    private func handleMonitorDisconnect() {
        llog("monitor reported disconnect; clearing and reconnecting")
        self.monitor = nil
        self.hasRequestedBackfillThisSession = false
        cancelNoDataWatchdog()
        cancelReconnect()
        startReconnectLoop()
    }

    /// Persistent reconnect loop. Keeps trying as long as the manager exists
    /// and we have saved state to reconnect with. Stops only on success
    /// (a monitor is adopted) or on Task cancellation (CGM deleted, manager
    /// torn down). The user never has to push a button.
    private func startReconnectLoop() {
        let task = Task { [weak self] in
            llog("reconnect loop: starting")
            defer {
                Task { @MainActor [weak self] in self?.isReconnecting = false }
                llog("reconnect loop: exiting")
            }
            while !Task.isCancelled {
                guard let self else { return }
                guard self.monitor == nil else { return }
                guard self.state.blePIN != nil, self.state.sensorSerial != nil else {
                    llog("reconnect loop: no saved state; aborting")
                    return
                }
                await MainActor.run { self.isReconnecting = true }
                try? await Task.sleep(nanoseconds: UInt64(Self.reconnectDelay * 1_000_000_000))
                if Task.isCancelled { break }
                // No bg task. The slow parts of reconnect (central.connect,
                // notify-stream reads) are iOS-driven — we're just awaiting
                // callbacks. If iOS suspends us mid-handshake, the sensor
                // hits its own protocol timeout and disconnects, which
                // surfaces via didDisconnectPeripheral → handleDisconnect →
                // all pending session awaits throw .disconnected — our
                // catch then loops back to a fresh attempt. The sensor is
                // the natural deadline; an artificial 30s bg-task budget
                // racing on top just makes us fight iOS's BLE wake schedule.
                await self.runReconnectOnce()
                if self.monitor != nil { return }
                // failure -> loop back, sleep, retry. Never gives up.
            }
        }
        Self.reconnectTasks[ObjectIdentifier(self)] = task
    }

    func cancelReconnect() {
        let key = ObjectIdentifier(self)
        if let task = Self.reconnectTasks[key] {
            task.cancel()
            Self.reconnectTasks.removeValue(forKey: key)
        }
    }

    private func runReconnectOnce() async {
        guard let blePIN = state.blePIN, let serial = state.sensorSerial else {
            return
        }
        let expectedPeripheral = state.peripheralID
        llog("reconnect: attempt starting (peripheralID=\(expectedPeripheral?.uuidString ?? "any"))")
        await MainActor.run {
            self.lastReconnectAttemptAt = Date()
        }
        // Pull whatever we previously persisted, but reconnect can still run
        // if Keychain has nothing — it'll just use the full handshake path.
        let cachedPhase5 = (try? LibreLoopKeychain.load(forSensorSerial: serial))?.phase5RawKey
        if cachedPhase5 != nil {
            llog("reconnect: cached phase5RawKey available; will try fast path first")
        } else {
            llog("reconnect: no cached phase5RawKey (legacy sensor or pre-fast-path pair); full handshake path only")
        }
        do {
            let outcome = try await LibreLoopPairingService().reconnect(
                scanner: scanner,
                blePIN: blePIN,
                phase5RawKey: cachedPhase5,
                expectedPeripheralID: expectedPeripheral
            ) { [weak self] stage in
                llog("reconnect stage: \(String(describing: stage))")
                self?.updateStatusDetail(Self.statusText(for: stage))
            }
            // If the fallback handshake re-derived a fresh phase5RawKey,
            // persist it. Cached path returns nil here (no re-derivation).
            let phase5ToPersist = outcome.phase5RawKey ?? cachedPhase5
            try LibreLoopKeychain.save(
                LibreLoopKeychain.SessionKeys(
                    kEnc: outcome.kEnc,
                    ivEnc: outcome.ivEnc,
                    phase5RawKey: phase5ToPersist,
                    receiverID: Self.receiverIDFromState(state.receiverID)
                ),
                forSensorSerial: serial
            )
            await MainActor.run {
                self.lastReconnectError = nil
                self.adopt(monitor: outcome.monitor)
            }
            llog("reconnect: succeeded via \(outcome.path == .cached ? "cached/direct" : "full") path")
        } catch {
            let message = (error as? CustomStringConvertible)?.description
                ?? error.localizedDescription
            llog("reconnect: attempt failed: \(message)")
            await MainActor.run {
                self.lastReconnectError = message
            }
        }
    }

    /// Trigger an automatic reconnect loop if we have saved state and aren't
    /// already running one. Called from app-launch state restore and from
    /// Loop's periodic fetchNewDataIfNeeded poll.
    func scheduleInitialReconnect() {
        let key = ObjectIdentifier(self)
        guard Self.reconnectTasks[key] == nil else {
            llog("reconnect: auto-trigger skipped (loop already running)")
            return
        }
        guard monitor == nil else {
            return
        }
        llog("reconnect: auto-trigger (launch or poll)")
        startReconnectLoop()
    }

    private static func mapTrend(_ trend: LibreLoopGlucoseSample.Trend) -> GlucoseTrend? {
        switch trend {
        case .notDetermined: return nil
        case .risingQuickly:  return .upUp
        case .rising:         return .up
        case .stable:         return .flat
        case .falling:        return .down
        case .fallingQuickly: return .downDown
        }
    }

    static func statusText(for stage: LibreLoopPairingService.Stage) -> String {
        switch stage {
        case .nfcScanning:   return "Scanning sensor"
        case .bleSearching:  return "Searching for sensor"
        case .bleConnecting: return "Connecting"
        case .handshaking:   return "Authenticating"
        }
    }

    func setState(_ newState: LibreLoopCGMManagerState) {
        state = newState
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
        notifyStateObservers()
    }
}
