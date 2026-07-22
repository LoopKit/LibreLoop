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
        llog("NFC response applied: serial=\(response.sensorSerial) receiverID=\(String(format: "0x%08x", response.receiverID)) bleAddress=\(response.bleAddress ?? "nil") blePIN bytes=\(response.blePIN.count)")
        cancelReconnect()
        var newState = state
        newState.receiverID = withUnsafeBytes(of: response.receiverID.littleEndian) { Data($0) }
        // Persist the receiver identity app-wide (fixed Keychain key) so it
        // survives a rawState wipe / plugin remove+re-add, and so future pairs
        // (and recoveries) reuse it. Covers .recovery and migrates legacy
        // random IDs to the stable key.
        LibreLoopKeychain.saveAppReceiverID(response.receiverID)
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
        // New sensor — clear any prior replace/error state.
        newState.sensorNeedsReplacement = false
        newState.sensorEndedNormally = false
        setState(newState)

        emitSensorStartEvent(for: newState)

        // New sensor — re-evaluate attention from scratch.
        lastSensorAttention = nil

        adopt(monitor: outcome.monitor)
    }

    /// Tell Loop's `CgmEventStore` that a new sensor session began. Mirrors
    /// the G7CGMManager pattern -- a `.sensorStart` event lets Loop's
    /// sensor-history view and retrospective analysis attribute glucose
    /// data to a specific sensor session. Without it, Loop has no record
    /// of when the Libre 3 session began other than inference from the
    /// first sample timestamp.
    ///
    /// `deviceIdentifier` is formatted as `<sensorSerial>:<receiverIDHex>`
    /// so a single sensor paired against different receivers produces
    /// distinct events.
    private func emitSensorStartEvent(for newState: LibreLoopCGMManagerState) {
        guard let serial = newState.sensorSerial, let activatedAt = newState.activatedAt else { return }
        let identifier = Self.deviceIdentifier(serial: serial, receiverID: newState.receiverID)
        let lifetime = newState.wearDurationMinutes.map { TimeInterval($0) * 60 }
            ?? LibreLoopSensorLifecycle.activeDuration
        let warmup = newState.warmupDurationMinutes.map { TimeInterval($0) * 60 }
            ?? LibreLoopSensorLifecycle.warmupDuration
        let event = PersistedCgmEvent(
            date: activatedAt,
            type: .sensorStart,
            deviceIdentifier: identifier,
            expectedLifetime: lifetime,
            warmupPeriod: warmup
        )
        llog("emitting CgmEvent .sensorStart deviceIdentifier=\(identifier) activatedAt=\(activatedAt)")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: [event])
        }
    }

    /// `<sensorSerial>:<receiverIDHex>` -- matches the existing settings-view
    /// formatting so the on-screen "Receiver ID" debug row and the
    /// CgmEvent identifier are derivable from each other.
    static func deviceIdentifier(serial: String, receiverID: Data?) -> String {
        let hex = (receiverID ?? Data()).map { String(format: "%02x", $0) }.joined()
        return hex.isEmpty ? serial : "\(serial):\(hex)"
    }

    func adopt(monitor: LibreLoopSensorMonitor) {
        guard !isDeleted else {
            llog("adopt: manager deleted; discarding monitor")
            return
        }
        let receiverIDLog = Self.receiverIDFromState(state.receiverID).map { String(format: "0x%08x", $0) } ?? "nil"
        llog("ble: adopted monitor (connected); sensor=\(state.sensorSerial ?? "nil") receiverID=\(receiverIDLog)")
        // Recovered — clear any standing "re-scan needed" alert/state.
        if hasIssuedReScanAlert {
            hasIssuedReScanAlert = false
            let id = Alert.Identifier(managerIdentifier: pluginIdentifier, alertIdentifier: Self.needsReScanAlertID)
            let delegate = cgmManagerDelegate
            Task { await delegate?.retractAlert(identifier: id) }
        }
        self.monitor = monitor
        // Session established -- stop any failure-recovery scan armed by the reconnect re-arm.
        scanner.stopScan()
        self.connectedAt = Date()
        // Fresh session: hasn't streamed a reading yet. Drives the
        // connect→no-stream livelock accounting in handleMonitorDisconnect.
        self.currentSessionProducedData = false
        // Each new BLE session gets its own backfill window.
        self.hasRequestedBackfillThisSession = false
        self.backfillFailuresThisSession = 0
        self.backfillForwardedLifeCounts.removeAll(keepingCapacity: true)
        self.lastHistoricalPageAt = nil
        monitor.setHandlers(
            onReading: { [weak self] sample in self?.ingest(sample) },
            onDisconnect: { [weak self] in self?.handleMonitorDisconnect() },
            onStatus: { [weak self] text in self?.updateStatusDetail(text) },
            onHistoricalPage: { [weak self] page in self?.handleHistoricalPage(page) },
            onClinicalRecord: { [weak self] record in self?.handleClinicalRecord(record) },
            onEmbeddedHistorical: { [weak self] lifeCount, mgdl in self?.captureEmbeddedHistorical(lifeCount: lifeCount, mgdl: mgdl) },
            onPatchStatus: { [weak self] status in self?.handlePatchStatus(status) },
            onLifeCount: { [weak self] lifeCount in self?.handleLifeCount(lifeCount) },
            onRawRead: { [weak self] record in self?.captureRead(record) }
        )
        monitor.start()
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
        // Clinical backfill is per-minute; covering a multi-hour disconnect at
        // 1-min resolution floods Loop with points. Limit clinical to a recent
        // window (the older gap is still covered at 5-min by historical), so we
        // get fine detail near "now" and coarse fill for old gaps.
        let recentClinicalWindow: UInt16 = 30
        let clinicalFrom: UInt16 = (currentLifeCount > recentClinicalWindow && currentLifeCount &- recentClinicalWindow > from)
            ? currentLifeCount &- recentClinicalWindow
            : from
        Task { [weak self, weak monitor] in
            guard let monitor else { return }
            do {
                try await monitor.requestHistoricalBackfill(fromLifeCount: from)
            } catch {
                guard let self else { return }
                self.backfillFailuresThisSession += 1
                llog("backfill request failed (\(self.backfillFailuresThisSession)/\(Self.maxBackfillFailuresPerSession)): \(String(describing: error))")
                if self.backfillFailuresThisSession < Self.maxBackfillFailuresPerSession {
                    self.hasRequestedBackfillThisSession = false   // retry on next reading
                } else {
                    llog("backfill giving up for this session after \(self.backfillFailuresThisSession) failures; will retry on reconnect")
                    // leave hasRequestedBackfillThisSession = true so we stop
                    // hammering the sensor (and churning) every ~60s.
                }
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
                    try await monitor.requestClinicalBackfill(fromLifeCount: clinicalFrom)
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
        notifySensorAttentionIfNeeded(status)
    }

    /// Surface the sensor's self-reported attention state (LibreCRKit e69dbd6's
    /// `Libre3SensorAttention`) to the user via Loop's AlertManager. Only the
    /// actionable end states (replace / ended) raise an alert; transient
    /// check-sensor and clears are logged and retract any prior alert. Patch
    /// status arrives ~once a minute, so we only act when the state changes.
    private func notifySensorAttentionIfNeeded(_ status: PatchStatus) {
        // A code-7 "transmission error" (`Libre3SensorError.transmissionError`)
        // is a transient comms fault, not a terminal replace condition — the
        // sensor keeps producing valid glucose. LibreCRKit's coarse attention
        // mapping lumps code 7 in with code 8 (terminated) as `.replaceSensor`;
        // downgrade it here to a soft, retractable `.checkSensor` notice so it
        // never marks the sensor inoperable or stops Loop.
        let attention: Libre3SensorAttention = status.sensorError == .transmissionError
            ? .checkSensor
            : status.sensorAttention
        guard attention != lastSensorAttention else { return }
        lastSensorAttention = attention
        llog("sensor attention: \(attention) (rawAttention=\(status.sensorAttention), sensorError=\(status.sensorError), patchState=\(status.patchStateKind), replace=\(status.shouldNotifyReplaceSensor))")

        // Persist the replace/ended state so the lifecycle, status highlight,
        // CGM page, and isInoperable all reflect "Replace sensor" — and survive
        // an app relaunch. Cleared when the sensor reports healthy again.
        let needsReplacement = (attention == .replaceSensor || attention == .sensorEnded)
        // A normal end-of-life (`sensorEnded`) surfaces as "Expired"; an early
        // failure (`replaceSensor`) as "Sensor failed". Both need replacement.
        let endedNormally = needsReplacement && attention == .sensorEnded
        if state.sensorNeedsReplacement != needsReplacement || state.sensorEndedNormally != endedNormally {
            var updated = state
            updated.sensorNeedsReplacement = needsReplacement
            updated.sensorEndedNormally = endedNormally
            setState(updated)
            // Push a CGM status update so Loop's HUD re-reads cgmStatusHighlight /
            // isInoperable immediately (there's no new glucose to trigger it).
            notifyStatusObservers()
        }

        let identifier = Alert.Identifier(managerIdentifier: pluginIdentifier,
                                          alertIdentifier: Self.sensorAttentionAlertID)
        let delegate = cgmManagerDelegate
        let content: (title: String, body: String, level: Alert.InterruptionLevel)?
        switch attention {
        case .replaceSensor:
            content = (LocalizedString("Replace sensor", comment: "Sensor failure alert title"),
                       LocalizedString("Your FreeStyle Libre 3 sensor has stopped working and needs to be replaced to resume CGM readings.", comment: "Sensor failure alert body"),
                       .timeSensitive)
        case .sensorEnded:
            content = (LocalizedString("Sensor ended", comment: "Sensor ended alert title"),
                       LocalizedString("Your FreeStyle Libre 3 sensor session has ended. Replace it to resume CGM readings.", comment: "Sensor ended alert body"),
                       .timeSensitive)
        case .checkSensor where status.sensorError == .transmissionError:
            // Transient comms fault (code 7). Soft, retractable notice that does
            // not interrupt or stop Loop; readings resume on their own. Retracted
            // as soon as the sensor reports a healthy status again.
            content = (LocalizedString("Check sensor", comment: "Sensor check alert title"),
                       LocalizedString("Loop is having trouble communicating with your FreeStyle Libre 3 sensor. CGM readings may pause briefly and should resume automatically. No action is needed unless this keeps happening.", comment: "Sensor check alert body (transient transmission error)"),
                       .active)
        case .checkSensor, .none, .unknown:
            // Other transient/cleared states — don't alert; retract any standing one.
            content = nil
        }

        guard let content else {
            Task { await delegate?.retractAlert(identifier: identifier) }
            return
        }
        let alert = Alert(
            identifier: identifier,
            foregroundContent: .init(title: content.title, body: content.body, acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledge button")),
            backgroundContent: .init(title: content.title, body: content.body, acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledge button")),
            trigger: .immediate,
            interruptionLevel: content.level
        )
        Task { await delegate?.issueAlert(alert) }
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
        // Mark that this monitor session has actually streamed — a healthy
        // disconnect, not a connect→arm-fail cycle (see handleMonitorDisconnect).
        currentSessionProducedData = true
        recordSample(sample)
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
        // (lifeCount, minutes since activation), which is authoritative. Normally
        // set once and left alone — later readings shouldn't shift it (small
        // drift would otherwise jitter the lifecycle bar). But self-heal a large
        // disagreement: a switch-receiver pairing that stamped activatedAt=now on
        // an already-old sensor would otherwise show a false "warmup" / wrong
        // expiry forever (it's non-nil, so the set-once branch never corrects it).
        // The sensor's age wins when off by more than half an hour.
        let derivedActivatedAt = sample.date.addingTimeInterval(-TimeInterval(sample.lifeCount) * 60)
        if let current = updated.activatedAt {
            if abs(current.timeIntervalSince(derivedActivatedAt)) > 30 * 60 {
                llog("activatedAt correction: stored=\(current) derived=\(derivedActivatedAt) lifeCount=\(sample.lifeCount); trusting sensor age")
                updated.activatedAt = derivedActivatedAt
            }
        } else {
            updated.activatedAt = derivedActivatedAt
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
                // Same scheme as realtime ("libreloop-<serial>-<lifeCount>") so
                // a given minute has ONE identity in Loop regardless of source
                // (realtime / historical / clinical) and can't become a
                // duplicate point at the same timestamp.
                syncIdentifier: "libreloop-\(serial)-\(sample.lifeCount)",
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
        // Capture every clinical record for the debug stream view (incl. raw
        // channels and realtime-duplicate minutes), independent of forwarding.
        captureClinicalStream(record)
        guard let activatedAt = state.activatedAt else {
            llog("clinical record received before activatedAt known; deferring")
            return
        }
        let serial = state.sensorSerial ?? "unknown"
        let realtimeLifeCounts = Set(recentSamples.map { $0.lifeCount })

        // Forward only the per-minute `currentGlucoseMgDL` at
        // `record.lifeCount`. Per upstream LibreCRKit guidance:
        // `currentGlucose` is keyed at lifeCount (offset 0) and safe
        // to plot at its own time, while `historicGlucoseRaw` is
        // redundant with the historical samples embedded in realtime
        // frames and shouldn't be keyed at this record's lifeCount.
        // Pass-2 historical backfill (22 min post-reconnect) covers
        // the gap between paged-historical and realtime resume.
        if let mgdl = record.currentGlucoseMgDL {
            forwardClinicalSample(
                mgdl: mgdl,
                lifeCount: record.lifeCount,
                kind: "current",
                serial: serial,
                activatedAt: activatedAt,
                realtimeLifeCounts: realtimeLifeCounts
            )
        }
    }

    private func forwardClinicalSample(
        mgdl: UInt16,
        lifeCount: UInt16,
        kind: String,
        serial: String,
        activatedAt: Date,
        realtimeLifeCounts: Set<UInt16>
    ) {
        // Thin clinical gap-fill to the 5-minute historical grid. Loop only
        // needs ~5-min CGM cadence; forwarding every 1-min clinical record
        // produced a dense 1-min cluster on the graph. lifeCount % 5 == 0
        // matches the historical backfill grid (so the two dedup cleanly) and
        // still fills the recent window historical can't reach yet — at 5-min
        // resolution. Off-grid minutes are dropped here but still captured for
        // the debug stream (captureClinicalStream runs before this).
        guard lifeCount % 5 == 0 else { return }
        if realtimeLifeCounts.contains(lifeCount) {
            llog("clinical \(kind) at lifeCount=\(lifeCount) dropped: realtime-dup")
            return
        }
        if backfillForwardedLifeCounts.contains(lifeCount) {
            llog("clinical \(kind) at lifeCount=\(lifeCount) dropped: backfill-dup")
            return
        }
        let date = activatedAt.addingTimeInterval(TimeInterval(lifeCount) * 60)
        let sample = NewGlucoseSample(
            date: date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(mgdl)),
            condition: nil,
            trend: nil,
            trendRate: nil,
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "libreloop-\(serial)-\(lifeCount)",
            syncVersion: 1,
            device: device
        )
        backfillForwardedLifeCounts.insert(lifeCount)
        llog("forwarded clinical \(kind) sample to Loop: \(mgdl) mg/dL lifeCount=\(lifeCount) sampleDate=\(date.timeIntervalSince1970)")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData([sample]))
        }
    }

    func handleMonitorDisconnect() {
        // Tear the old monitor down before dropping the reference: stop() cancels
        // its notifications task AND the silence watchdog. Without this the
        // watchdog outlives the dead session and keeps firing readPatchStatus
        // (each a 5s timeout) every ~60s through the whole outage — noise that
        // buries the real connect/disconnect events in the log.
        self.monitor?.stop()
        self.monitor = nil
        self.connectedAt = nil
        self.hasRequestedBackfillThisSession = false
        self.backfillFailuresThisSession = 0
        guard !isDeleted else {
            llog("monitor reported disconnect; manager deleted, not reconnecting")
            return
        }
        // Distinguish a healthy stream-then-drop from a connect→adopt→arm-fail
        // cycle that never streamed. The latter, repeated, is the CCCD-arming
        // livelock: the link connects and adopts a monitor every cycle (so the
        // reconnect-failure counter keeps resetting and nothing escalates),
        // but post-auth notification arming times out, so no glucose flows.
        if currentSessionProducedData {
            consecutiveNoStreamDisconnects = 0
        } else {
            consecutiveNoStreamDisconnects += 1
        }
        let liveAge = state.latestReadingTimestamp.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
        llog("monitor reported disconnect; clearing and reconnecting (streamedThisSession=\(currentSessionProducedData), consecutiveNoStreamCycles=\(consecutiveNoStreamDisconnects), lastLiveGlucose=\(liveAge))")
        if consecutiveNoStreamDisconnects >= Self.noStreamLivelockWarnThreshold {
            llog("WARNING: \(consecutiveNoStreamDisconnects) consecutive connect→no-stream cycles — sensor connects and adopts a monitor but post-auth notification arming keeps failing (CCCD notify-ack timeout), so no glucose flows. This is the arming livelock that has historically cleared only on a fresh characteristic discovery (e.g. app restart).")
        }
        // Don't cancel any in-flight reconnect attempt here. The session
        // backing this monitor is already dead; a reconnect Task that's
        // running is either a fresh handshake on a new link (which we must
        // not kill) or will fail on its own when its session ops throw.
        // scheduleReconnect's single-flight guard keeps us from racing.
        // Re-register for connection events on every disconnect, mirroring
        // G7's scanForPeripheral() pattern. The registration persists through
        // app suspension; re-issuing it ensures iOS has a fresh subscription
        // even if the prior one was cleared by a state-restoration cycle.
        if let id = state.peripheralID {
            scanner.registerForConnectionEvents(peripheralIDs: [id])
            llog("re-registered for connection events on peripheral \(id.uuidString)")
        }
        scheduleReconnect()
    }

    /// Schedule a single reconnect attempt. Safe to call from any CB
    /// event handler (state .poweredOn, didDisconnect, didFailToConnect),
    /// app-lifecycle hooks, or Loop's periodic fetchNewDataIfNeeded.
    ///
    /// Idempotent: if an attempt is already in flight, this is a no-op.
    /// If the attempt fails to adopt a monitor, the completion handler
    /// asks CoreBluetooth to drop the link via cancelPeripheralConnection.
    /// CB then fires didDisconnect, which calls back into this function
    /// to schedule the next attempt. That makes retries fully event-
    /// driven -- no polling loop, no Task.sleep, no shared state. CB
    /// handles the wait-for-reachability between attempts.
    func scheduleReconnect() {
        guard !isDeleted else {
            llog("reconnect: manager deleted; not scheduling")
            return
        }
        guard monitor == nil else { return }
        guard state.blePIN != nil, state.sensorSerial != nil else {
            llog("reconnect: no saved state; not scheduling")
            return
        }
        // (Re-)arm the CB connect intent first, before any debounce.
        // We should NEVER sit "disconnected with no CB intent
        // pending" -- otherwise the peripheral returning to range
        // generates no callback. BUT only call requestConnect when
        // the peripheral isn't already .connected/.connecting:
        // calling central.connect on an already-connected peripheral
        // on iOS empirically re-fires didConnect, and since our
        // didConnect handler calls scheduleReconnect, that produces a
        // tight loop bounded only by `monitor == nil`. Field log
        // captured 3228 didConnect events in 1 second during the
        // ~2.2s handshake window because of this.
        if let peripheralID = state.peripheralID,
           let peripheral = scanner.retrievePeripherals(withIdentifiers: [peripheralID]).first,
           peripheral.state != .connected, peripheral.state != .connecting {
            llog("ble: requesting connect \(peripheral.identifier.uuidString) (peripheral state=\(peripheral.state.rawValue))")
            scanner.requestConnect(peripheral)
        }
        guard reconnectAttempt == nil else {
            return
        }
        // Burst-debounce: when CB emits a flurry of disconnect events
        // (link flapping out of range), we'd otherwise schedule one
        // handshake Task per event. The CB connect intent we just
        // re-armed above is enough -- iOS will fire didConnect when
        // the peripheral comes back, and the listener will trigger a
        // fresh scheduleReconnect at that point. Coalescing the burst
        // means we don't churn Task lifecycle in the meantime.
        let now = Date()
        if let last = lastReconnectAttemptStartedAt, now.timeIntervalSince(last) < Self.minReconnectInterval {
            return
        }
        lastReconnectAttemptStartedAt = now
        llog("reconnect: scheduling attempt")
        isReconnecting = true
        let scanner = self.scanner
        let peripheralID = self.state.peripheralID
        reconnectAttempt = Task { [weak self] in
            guard let self else { return }
            await self.runReconnectOnce()
            await MainActor.run {
                self.isReconnecting = false
                self.reconnectAttempt = nil
            }
            // After a failed attempt we MUST end up in one of two
            // safe states: (a) CB has a connect intent pending and
            // we're waiting on it, or (b) a fresh handshake Task is
            // in flight. NEVER "disconnected with nothing pending",
            // which is the field-bug state -- PairingFlowError 7
            // failed handshake, link already down, no CB event
            // arriving to drive a retry, manager sat idle for 40
            // minutes. CB events alone are NOT a sufficient retry
            // trigger when the failure path doesn't go through CB.
            guard await MainActor.run(body: { self.monitor == nil }) else { return }
            if let peripheralID,
               let peripheral = scanner.retrievePeripherals(withIdentifiers: [peripheralID]).first,
               peripheral.state == .connected || peripheral.state == .connecting {
                // Active link survived the handshake failure --
                // drop it and let the resulting didDisconnect route
                // through the events listener (which calls
                // scheduleReconnect). Calling scheduleReconnect
                // here too would be a duplicate within ms.
                scanner.cancelConnection(peripheral)
            } else {
                // No active link, no in-flight Task, no CB event pending. Re-arm the standing connect --
                // BUT a bare standing connect can be inert here: a restored-cache handshake failure can leave
                // the peripheral .disconnected with iOS silently dropping the pending connect (field log:
                // 15-min stall, diagnostic showed peripheral.state=0). The failed ATTEMPT is our error
                // evidence, so ALSO engage a scan: it makes iOS actively reacquire the sensor, and a fresh
                // discovery re-declares the connect on a fresh handle (.didDiscover) -> a fresh connect.
                // Stopped the moment a session is established (see `self.monitor = monitor`).
                await MainActor.run {
                    self.scheduleReconnect()
                    if self.scanner.centralState == .poweredOn {
                        self.scanner.startScan()
                    }
                }
            }
        }
    }

    func cancelReconnect() {
        reconnectAttempt?.cancel()
        reconnectAttempt = nil
    }

    /// True when the BLE link is up but the sensor has gone mute -- a
    /// firmware glitch we can't otherwise detect, since CB's supervision
    /// timeout only fires on a genuinely lost link, not on a connected-but-
    /// silent peer. A Libre 3 emits a realtime reading ~once a minute over a
    /// live link, so 11 minutes of silence (covering ~2 of Loop's ~5-min
    /// runtime cycles) without a false trigger means it's stopped talking.
    @MainActor
    var isConnectedButMute: Bool {
        guard monitor != nil, let connectedAt else { return false }
        // Anchor on the more recent of "link came up" and "last reading":
        // covers both a session that never delivered and one that went quiet.
        let lastActivity = max(connectedAt, state.latestReadingTimestamp ?? .distantPast)
        return Date().timeIntervalSince(lastActivity) > Self.muteForceDisconnectInterval
    }

    /// Recovery for the connected-but-mute case. Dropping the link makes CB
    /// emit didDisconnect, which routes through the events listener into
    /// scheduleReconnect -- the same recovery path as a natural disconnect.
    /// Only ever called when we hold a live link (see isConnectedButMute).
    @MainActor
    func forceDisconnectForMuteRecovery() {
        guard let peripheralID = state.peripheralID,
              let peripheral = scanner.retrievePeripherals(withIdentifiers: [peripheralID]).first,
              peripheral.state == .connected || peripheral.state == .connecting else {
            return
        }
        llog("connected \(connectedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1)s with no data; forcing disconnect to recover")
        scanner.cancelConnection(peripheral)
    }

    private func runReconnectOnce() async {
        guard let blePIN = state.blePIN, let serial = state.sensorSerial else {
            return
        }
        let expectedPeripheral = state.peripheralID
        let receiverIDLog = Self.receiverIDFromState(state.receiverID).map { String(format: "0x%08x", $0) }
            ?? LibreLoopKeychain.loadAppReceiverID().map { String(format: "0x%08x (app)", $0) }
            ?? "nil"
        llog("reconnect: attempt starting (peripheralID=\(expectedPeripheral?.uuidString ?? "any") receiverID=\(receiverIDLog))")
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
            let backoff = await MainActor.run { () -> TimeInterval in
                self.consecutiveReconnectFailures += 1
                if self.consecutiveReconnectFailuresStartedAt == nil {
                    self.consecutiveReconnectFailuresStartedAt = Date()
                }
                let count = self.consecutiveReconnectFailures
                let elapsed = self.consecutiveReconnectFailuresStartedAt
                    .map { Date().timeIntervalSince($0) } ?? 0
                if count >= Self.reScanThresholdCount {
                    // BLE reconnect is persistently failing — the cached session
                    // is being rejected and there's no full-handshake recovery for
                    // an active sensor. Tell the user the truth (re-scan) instead
                    // of surfacing the cryptic handshake error, and alert once.
                    self.lastReconnectError = String(format: LocalizedString("Can't reconnect after %d tries — re-scan the sensor to reconnect (or replace it if it was recently inserted).", comment: "Reconnect-failed status after many attempts"), count)
                    if !self.hasIssuedReScanAlert {
                        self.hasIssuedReScanAlert = true
                        self.issueReScanAlert()
                    }
                } else if count >= Self.reconnectErrorDisplayThresholdCount
                    || elapsed >= Self.reconnectErrorDisplayThresholdInterval {
                    // Only surface the raw error once the failure run is long
                    // enough that a single self-recovering blip stays silent.
                    self.lastReconnectError = message
                }
                return Self.reconnectBackoff(failures: count)
            }
            // Back off before the attempt completes (single-flight, so this gates
            // the next attempt) so a marginal/wedged link isn't hammered. Sleep is
            // cancellable via cancelReconnect (delete / new pairing).
            if backoff > 0 {
                llog("reconnect: backing off \(Int(backoff))s after failure")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    /// One-time, time-sensitive alert telling the user BLE reconnect is stuck and
    /// they should re-scan (or replace) the sensor. Routed through AlertManager.
    private func issueReScanAlert() {
        let delegate = cgmManagerDelegate
        let identifier = Alert.Identifier(managerIdentifier: pluginIdentifier,
                                          alertIdentifier: Self.needsReScanAlertID)
        let title = LocalizedString("Re-scan sensor", comment: "Reconnect-failed alert title")
        let body = String(format: LocalizedString("%1$@ can't reconnect to your FreeStyle Libre 3. Scan the sensor again to resume CGM readings. If it was recently inserted and keeps failing, the sensor may be defective — replace it.", comment: "Reconnect-failed alert body (1: appName)"), Bundle.main.bundleDisplayName)
        let ok = LocalizedString("OK", comment: "Alert acknowledge button")
        let alert = Alert(
            identifier: identifier,
            foregroundContent: .init(title: title, body: body, acknowledgeActionButtonLabel: ok),
            backgroundContent: .init(title: title, body: body, acknowledgeActionButtonLabel: ok),
            trigger: .immediate,
            interruptionLevel: .timeSensitive
        )
        Task { await delegate?.issueAlert(alert) }
    }

    private static func mapTrend(_ trend: LibreLoopGlucoseSample.Trend) -> GlucoseTrend? {
        LibreLoopGlucoseDisplay.mapTrend(trend)
    }

    static func statusText(for stage: LibreLoopPairingService.Stage) -> String {
        switch stage {
        case .nfcScanning:   return LocalizedString("Scanning sensor", comment: "Pairing stage: NFC scanning")
        case .bleSearching:  return LocalizedString("Searching for sensor", comment: "Pairing stage: BLE searching")
        case .bleConnecting: return LocalizedString("Connecting", comment: "Pairing stage: connecting")
        case .handshaking:   return LocalizedString("Authenticating", comment: "Pairing stage: handshaking")
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

extension Bundle {
    /// The host app's display name (Loop, Trio, a rebrand, …). `Bundle.main`
    /// is the running app, not this plugin, so this resolves to whatever app
    /// embedded LibreLoop. Used for app-name substitution in user-facing alerts.
    var bundleDisplayName: String {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Loop"
    }
}
