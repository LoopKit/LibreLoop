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

    /// Schedule sensor expiry alerts through Loop's AlertManager when
    /// `activatedAt` is new (or first known). Returns the value to store
    /// in `expiryAlertsScheduledForActivatedAt`. Idempotent — called from
    /// `ingest(_:)` on every reading; returns the existing tracker value
    /// unchanged when nothing needs rescheduling. Fire-and-forget: the
    /// AlertManager handles persistence so if the delegate is briefly nil
    /// we'll retry on the next reading.
    func scheduleExpiryAlertsIfNeeded(activatedAt: Date?, currentTracker: Date?) -> Date? {
        guard let activatedAt else { return currentTracker }
        if currentTracker == activatedAt { return currentTracker }
        let sensorLifetime: TimeInterval = state.wearDurationMinutes
            .map { TimeInterval($0) * 60 }
            ?? LibreLoopSensorLifecycle.activeDuration
        let alerts = LibreLoopExpiryAlerts.scheduledAlerts(
            managerIdentifier: pluginIdentifier,
            sensorActivatedAt: activatedAt,
            lifetime: sensorLifetime
        )
        let delegate = cgmManagerDelegate
        if alerts.isEmpty {
            llog("expiry alerts: all trigger times in the past for activatedAt=\(activatedAt); marking scheduled")
        } else {
            llog("expiry alerts: scheduling \(alerts.count) alert(s) for activatedAt=\(activatedAt)")
            Task {
                for alert in alerts {
                    await delegate?.issueAlert(alert)
                }
            }
        }
        return activatedAt
    }

    func retractExpiryAlerts() {
        let delegate = cgmManagerDelegate
        let identifiers = LibreLoopExpiryAlerts.allIdentifiers.map {
            Alert.Identifier(managerIdentifier: pluginIdentifier, alertIdentifier: $0)
        }
        llog("expiry alerts: retracting \(identifiers.count) identifier(s)")
        Task {
            for identifier in identifiers {
                await delegate?.retractAlert(identifier: identifier)
            }
        }
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
        if let wear = response.wearDurationMinutes, wear > 0 {
            newState.wearDurationMinutes = wear
        }
        if let warmup = response.warmupDurationMinutes, warmup > 0 {
            newState.warmupDurationMinutes = warmup
        }
        if let gen = response.generation {
            newState.generation = gen
        }
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
        newState.firstReadingAt = nil
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
            onClinicalRecord: { [weak self] record in self?.handleClinicalRecord(record) },
            onEmbeddedHistorical: { [weak self] lifeCount, mgdl in
                self?.handleEmbeddedHistorical(lifeCount: lifeCount, mgdl: mgdl)
            },
            onPatchStatus: { [weak self] status in self?.handlePatchStatus(status) },
            onLifeCount: { [weak self] lifeCount in self?.handleLifeCount(lifeCount) }
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
    ///
    /// Two-pass backfill strategy:
    /// - Pass 1 (immediate): covers the outage window from the watermark up
    ///   to whatever the sensor has committed at reconnect time (~T-17 min
    ///   due to the sensor's internal commit lag).
    /// - Pass 2 (22-min delay): covers the ~17-min tail window the sensor
    ///   hadn't committed yet at reconnect, using the current watermark at
    ///   fire time so it picks up exactly what embedded-historical harvest
    ///   may have missed. Combined with the embedded harvest these two
    ///   passes fully close the post-reconnect gap.
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
                    break
                } catch {
                    let isLast = (i == backoffs.count - 1)
                    let prefix = isLast ? "clinical backfill failed after \(i + 1) attempts" : "clinical backfill attempt \(i + 1) failed, will retry"
                    llog("\(prefix): \(String(describing: error))")
                }
            }

            // Pass 2: wait 22 min then re-request historical from the
            // current watermark. The sensor commits 5-min historical
            // entries with ~17 min lag, so entries for T-17..T weren't
            // in the sensor's buffer at reconnect. By T+22 they are,
            // and the watermark has advanced via embedded-historical
            // harvest to reflect only what we're still missing.
            try? await Task.sleep(nanoseconds: 22 * 60 * 1_000_000_000)
            guard !Task.isCancelled, let followUpMonitor = self.monitor else { return }
            let watermark = self.state.lastHistoricalLifeCount ?? from
            let followUpFrom: UInt16 = watermark > 5 ? watermark - 5 : 1
            llog("backfill pass 2: requesting from lifeCount=\(followUpFrom) (watermark=\(watermark))")
            do {
                try await followUpMonitor.requestHistoricalBackfill(fromLifeCount: followUpFrom)
            } catch {
                llog("backfill pass 2 failed: \(String(describing: error))")
            }
        }
    }

    /// Handle a sensor-broadcast PatchStatus frame. Field observation shows
    /// the Libre 3 doesn't reliably broadcast patchStatus during initial
    /// warmup; this path stays as a fallback but in practice the
    /// onLifeCount handler is what fills activatedAt during that window.
    func handlePatchStatus(_ status: PatchStatus) {
        seedActivatedAtIfNeeded(currentLifeCount: status.currentLifeCount, source: "patch status")
    }

    /// Handle the per-minute lifeCount surfaced by every realtime glucose
    /// frame -- including warmup frames whose mgdl is nil. Two jobs:
    ///
    /// 1. Back-derive activatedAt before the first actionable reading
    ///    lands (warmup can be 60 min on a fresh sensor).
    /// 2. Push a status update to Loop's CGMManagerStatusObservers so the
    ///    HUD progress bar advances every minute during warmup. Without
    ///    this, the HUD only refreshes on Loop's 5-min cycle.
    func handleLifeCount(_ lifeCount: UInt16) {
        seedActivatedAtIfNeeded(currentLifeCount: Int16(clamping: Int(lifeCount)), source: "realtime lifeCount")
        notifyStatusObservers()
    }

    /// Set `activatedAt` from a sensor-reported lifeCount if (and only if)
    /// it isn't already pinned. We never shift the anchor mid-session --
    /// later frames with later lifeCounts would otherwise jitter the
    /// lifecycle bar by a minute or two.
    private func seedActivatedAtIfNeeded(currentLifeCount: Int16, source: String) {
        guard state.activatedAt == nil else { return }
        let now = Date()
        let activatedAt = now.addingTimeInterval(-TimeInterval(currentLifeCount) * 60)
        llog("\(source): deriving activatedAt from lifeCount=\(currentLifeCount) -> \(activatedAt)")
        var updated = state
        updated.activatedAt = activatedAt
        updated.expiryAlertsScheduledForActivatedAt = scheduleExpiryAlertsIfNeeded(
            activatedAt: activatedAt,
            currentTracker: updated.expiryAlertsScheduledForActivatedAt
        )
        setState(updated)
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
        // Advance the backfill watermark on every successful realtime
        // ingest. Without this, `lastHistoricalLifeCount` only moves
        // forward on backfill responses, so after hours of healthy
        // realtime traffic the watermark stays frozen at the last
        // backfill point. A reconnect would then trigger a huge
        // catch-up request that mostly hits the realtime-dup filter
        // (and, empirically, can overrun the sensor's BLE pacing and
        // stall realtime entirely). Bumping it here means a reconnect
        // backfill only covers what we actually missed.
        let priorWatermark = updated.lastHistoricalLifeCount ?? 0
        if sample.lifeCount > priorWatermark {
            updated.lastHistoricalLifeCount = sample.lifeCount
        }
        // Back-derive activation timestamp from the sensor's own age counter
        // (lifeCount, minutes since activation). Only set it once -- later
        // readings shouldn't shift it (small drift would otherwise jitter the
        // lifecycle bar).
        if updated.activatedAt == nil {
            updated.activatedAt = sample.date.addingTimeInterval(-TimeInterval(sample.lifeCount) * 60)
        }
        updated.expiryAlertsScheduledForActivatedAt = scheduleExpiryAlertsIfNeeded(
            activatedAt: updated.activatedAt,
            currentTracker: updated.expiryAlertsScheduledForActivatedAt
        )
        // If the sensor is still sending actionable readings past what we
        // stored as its wear duration (or our 14-day default for state
        // persisted before NFC wear-duration capture was added), the sensor
        // has a longer rated duration than we have on record. Extend
        // wearDurationMinutes 1 day beyond the observed lifeCount so the
        // lifecycle bar and expiry alerts stay accurate. This self-corrects
        // for Libre 3 Plus (15-day) sensors paired before the fix landed,
        // and for any future longer-duration variant.
        if sample.isActionable {
            let knownWear = updated.wearDurationMinutes
                ?? Int(LibreLoopSensorLifecycle.activeDuration / 60)
            if Int(sample.lifeCount) >= knownWear {
                let extended = Int(sample.lifeCount) + 24 * 60
                llog("lifeCount=\(sample.lifeCount) >= wearDuration=\(knownWear); sensor still actionable — extending wearDurationMinutes to \(extended)")
                updated.wearDurationMinutes = extended
            }
        }

        // First reading post-pair tells us the sensor is talking; that's
        // enough to leave the .pairingWarmup ("Stabilizing") state. The
        // actionability flag still gates dosing via isDisplayOnly per
        // forwarded sample -- the lifecycle doesn't need to wait on it.
        if updated.firstReadingAt == nil {
            updated.firstReadingAt = sample.date
        }
        setState(updated)

        notifyStateObservers()

        // Status detail moves out of "Waiting for first reading" the instant
        // any reading arrives, even unactionable ones -- the link is proven.
        if !sample.isActionable {
            updateStatusDetail("Reading received (display only)")
        } else {
            updateStatusDetail(nil)
        }

        // Non-actionable samples are forwarded as isDisplayOnly so Loop
        // shows them on the chart/HUD but excludes them from dosing math.
        // We also skip the dosing-cadence throttle for them -- it exists
        // to keep Loop's 5-min algorithm from jittering on minute-by-
        // minute updates, but display-only samples don't enter dosing.
        // This lets the user watch readings flow in during the post-
        // warmup stabilization window instead of seeing a frozen chart.
        //
        // BUT: when the sensor itself reports a hardware/data fault
        // (DQ or sensor condition issue), the value is unreliable at
        // the source -- forwarding it as display-only would still draw
        // a point on Loop's chart that the sensor said not to trust.
        // Drop those entirely; the badge on the Last Reading card and
        // the file log still record what the sensor sent us.
        if sample.hasBlockingIssue {
            llog("blocking issue \(sample.qualityIssue ?? "unknown"): \(Int(sample.valueMgDL)) mg/dL lifeCount=\(sample.lifeCount); not forwarding to Loop")
            recordForwardingOutcome(
                forLifeCount: sample.lifeCount,
                wasForwarded: false,
                skipReason: sample.qualityIssue ?? "Sensor reported fault"
            )
            return
        }

        let isDisplayOnly = !sample.isActionable

        if sample.isActionable,
           !state.experimentalMinuteByMinuteForwarding,
           let last = state.latestForwardedToLoopAt,
           sample.date.timeIntervalSince(last) < 270 {
            // Default-mode throttle: Loop's algorithm is paced around the
            // 5-minute CGM cadence other plugins emit, and per-minute
            // updates can shift dosing decisions in ways the cadence
            // wasn't tuned for. 4.5 min gives a 30-second slop under
            // 5 min so the natural cadence isn't blocked by jitter.
            // Opt-out is experimentalMinuteByMinuteForwarding.
            let age = Int(sample.date.timeIntervalSince(last))
            llog("throttled: \(Int(sample.valueMgDL)) mg/dL lifeCount=\(sample.lifeCount) (only \(age)s since last forward; experimental minute-by-minute mode is off)")
            recordForwardingOutcome(
                forLifeCount: sample.lifeCount,
                wasForwarded: false,
                skipReason: "Throttled (\(age)s since last forward)"
            )
            return
        }

        let loopCondition: GlucoseCondition?
        switch sample.condition {
        case .belowRange?: loopCondition = .belowRange
        case .aboveRange?: loopCondition = .aboveRange
        case nil:          loopCondition = nil
        }

        let newSample = NewGlucoseSample(
            date: sample.date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
            condition: loopCondition,
            trend: Self.mapTrend(sample.trend),
            trendRate: sample.rateOfChangeMgDLPerMinute.map {
                LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: isDisplayOnly,
            wasUserEntered: false,
            syncIdentifier: "libreloop-\(state.sensorSerial ?? "unknown")-\(sample.lifeCount)",
            syncVersion: 1,
            device: device
        )

        let displayTag = isDisplayOnly ? " (display-only)" : ""
        llog("forwarding to Loop\(displayTag): \(Int(sample.valueMgDL)) mg/dL lifeCount=\(sample.lifeCount) sampleDate=\(sample.date.timeIntervalSince1970)")
        if sample.isActionable {
            // Only advance the throttle clock on actionable samples so a
            // run of display-only forwards doesn't push out the next
            // actionable forward.
            var stamped = state
            stamped.latestForwardedToLoopAt = sample.date
            setState(stamped)
        }
        recordForwardingOutcome(forLifeCount: sample.lifeCount, wasForwarded: true, skipReason: nil)

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

    /// Forward the 5-min historical sample that the sensor pairs with
    /// every realtime glucose packet. Doing this continuously keeps the
    /// historical buffer aligned to "now minus ~17 min" without needing
    /// any post-reconnect re-request — the next session's disconnect
    /// window is the only gap a dedicated history backfill needs to
    /// cover. Pattern mirrors Juggluco's `saveLibre3Historyel` call on
    /// every 1-min glucose packet (and DiaBLE's
    /// `mergeHistoricSamples` from live packets).
    ///
    /// Fired on every realtime tick, so the dedup gate matters: the
    /// embedded historical sample only advances every 5 lifeCounts, so
    /// 4 of every 5 calls land in the backfill-dup early return.
    func handleEmbeddedHistorical(lifeCount: UInt16, mgdl: UInt16) {
        guard let activatedAt = state.activatedAt else { return }
        if backfillForwardedLifeCounts.contains(lifeCount) { return }
        // Realtime carries its own current-minute lifeCount; the
        // embedded historical's lifeCount is always older than (and
        // distinct from) any realtime lifeCount we've seen, so a
        // realtime-dup check would only trigger if the user briefly
        // disabled the embedded path. Cheap to include for safety.
        if recentSamples.contains(where: { $0.lifeCount == lifeCount }) { return }

        let serial = state.sensorSerial ?? "unknown"
        let date = activatedAt.addingTimeInterval(TimeInterval(lifeCount) * 60)
        let sample = NewGlucoseSample(
            date: date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(mgdl)),
            condition: nil,
            trend: nil,
            trendRate: nil,
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "libreloop-bkfill-\(serial)-\(lifeCount)",
            syncVersion: 1,
            device: device
        )
        backfillForwardedLifeCounts.insert(lifeCount)
        // Advance the historical watermark so reconnect backfill only
        // covers the genuine outage window. Mirrors the bump in
        // `handleHistoricalPage`.
        var updated = state
        let priorWatermark = updated.lastHistoricalLifeCount ?? 0
        if lifeCount > priorWatermark {
            updated.lastHistoricalLifeCount = lifeCount
            setState(updated)
        }
        llog("forwarded embedded historical sample to Loop: \(mgdl) mg/dL lifeCount=\(lifeCount) sampleDate=\(date.timeIntervalSince1970)")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData([sample]))
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
        // Re-register for connection events on every disconnect, mirroring
        // G7's scanForPeripheral() pattern. The registration persists through
        // app suspension; re-issuing it ensures iOS has a fresh subscription
        // even if the prior one was cleared by a state-restoration cycle.
        if let id = state.peripheralID {
            scanner.registerForConnectionEvents(peripheralIDs: [id])
            llog("re-registered for connection events on peripheral \(id.uuidString)")
        }
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
                // No pre-attempt sleep. connect() must be queued with iOS
                // immediately after a disconnect — if we yield via Task.sleep
                // before calling connect(), iOS can suspend the app with no
                // pending connect in its CB stack, and nothing will wake us.
                // G7's Thread.sleep(2) is a blocking call on a DispatchQueue
                // thread that doesn't yield to the scheduler; Task.sleep does.
                // The delay moves to after a failed attempt so retries still
                // have a brief pause without blocking the first attempt.
                await self.runReconnectOnce()
                if self.monitor != nil { return }
                // Retry after a brief pause so we don't spam the BLE stack
                // on repeated failures (sensor out of range, handshake error).
                try? await Task.sleep(nanoseconds: UInt64(Self.reconnectDelay * 1_000_000_000))
                if Task.isCancelled { break }
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
                self.consecutiveReconnectFailures = 0
                self.consecutiveReconnectFailuresStartedAt = nil
                self.adopt(monitor: outcome.monitor)
            }
            llog("reconnect: succeeded via \(outcome.path == .cached ? "cached/direct" : "full") path")
        } catch {
            let message = (error as? CustomStringConvertible)?.description
                ?? error.localizedDescription
            llog("reconnect: attempt failed: \(message)")
            await MainActor.run {
                self.consecutiveReconnectFailures += 1
                if self.consecutiveReconnectFailuresStartedAt == nil {
                    self.consecutiveReconnectFailuresStartedAt = Date()
                }
                // Only surface the error to the UI once the failure run
                // is long-running enough that the user would actually
                // want to know -- either many consecutive failures or
                // failures spanning beyond the recovery window.
                let count = self.consecutiveReconnectFailures
                let elapsed = self.consecutiveReconnectFailuresStartedAt
                    .map { Date().timeIntervalSince($0) } ?? 0
                if count >= Self.reconnectErrorDisplayThresholdCount
                    || elapsed >= Self.reconnectErrorDisplayThresholdInterval {
                    self.lastReconnectError = message
                }
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
        LibreLoopGlucoseDisplay.mapTrend(trend)
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
