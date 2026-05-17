import Foundation
import HealthKit
import LibreCRKit
import LoopAlgorithm
import LoopKit
import os.log
import UIKit


extension LibreLoopCGMManager {
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
                phase5RawKey: outcome.result.phase5RawKey
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
        monitor.setHandlers(
            onReading: { [weak self] sample in self?.ingest(sample) },
            onDisconnect: { [weak self] in self?.handleMonitorDisconnect() },
            onStatus: { [weak self] text in self?.updateStatusDetail(text) },
            onHistoricalPage: { [weak self] page in self?.handleHistoricalPage(page) }
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

    /// Wraps `work` in a UIApplication background task so iOS keeps us alive
    /// long enough to finish even when the app is backgrounded.
    ///
    /// Returns true if the work completed before the bg window expired;
    /// false on expiration. On expiration, the work Task is cancelled and
    /// we return WITHOUT waiting for it. Field log captured a 6h36m stall
    /// when the bg task expired mid-BLE handshake: LibreCRKit's
    /// continuation-based awaits don't honor cooperative cancellation, so a
    /// stuck workTask never resolves and `await workTask.value` would park
    /// indefinitely too. By bailing on expiration we let the reconnect
    /// loop's outer iterate to a fresh attempt next time iOS gives us
    /// runtime. The orphaned workTask is harmless — it'll either complete
    /// naturally or stay parked; the next reconnect's scanner.connect
    /// handles an already-connected peripheral.
    @discardableResult
    static func withBackgroundTask(name: String, _ work: @Sendable @escaping () async -> Void) async -> Bool {
        let app = await MainActor.run { UIApplication.shared }
        let workTask = Task { await work() }
        let idBox = TaskIdentifierBox()
        let expirationBox = ExpirationBox()
        let id = await MainActor.run {
            app.beginBackgroundTask(withName: name) {
                expirationBox.expired = true
                let taskID = idBox.value
                if taskID != .invalid {
                    llog("background task '\(name)' expired before work completed; abandoning in-flight work")
                    workTask.cancel()
                    app.endBackgroundTask(taskID)
                    idBox.value = .invalid
                }
            }
        }
        idBox.value = id
        if id == .invalid {
            llog("background task '\(name)' could not be started (app may be unable to extend runtime)")
        } else {
            llog("background task '\(name)' started id=\(id.rawValue)")
        }
        // Race work completion vs. bg-expiration. Whichever flips first wins.
        let completed: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await workTask.value
                return true
            }
            group.addTask {
                while !Task.isCancelled, !expirationBox.expired {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await MainActor.run {
            let taskID = idBox.value
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
                idBox.value = .invalid
                llog("background task '\(name)' ended id=\(taskID.rawValue)")
            }
        }
        return completed
    }

    private final class ExpirationBox: @unchecked Sendable {
        var expired: Bool = false
    }

    /// Reference container so the expiration handler and the post-work cleanup
    /// can race safely on the same identifier without forcing us into a
    /// @MainActor closure capture.
    private final class TaskIdentifierBox: @unchecked Sendable {
        var value: UIBackgroundTaskIdentifier = .invalid
    }

    /// Convert each historical sample into a NewGlucoseSample (when the page
    /// decoded mg/dL is present), push the batch to Loop's delegate, and
    /// advance `state.lastHistoricalLifeCount` so the next backfill picks
    /// up where we left off.
    func handleHistoricalPage(_ page: HistoricalReadingPage) {
        guard let activatedAt = state.activatedAt else {
            llog("backfill page received before activatedAt known; deferring")
            return
        }
        let serial = state.sensorSerial ?? "unknown"
        // Build the set of lifeCounts we've already forwarded as realtime.
        // Backfill samples for those lifeCounts use the sensor's smoothed/
        // historical pipeline and disagree with realtime by up to ±20 mg/dL
        // (verified in field logs). They land in Loop under a different
        // syncIdentifier, so without this filter Loop stores both values for
        // the same timestamp -- visible as two independent dots that disagree.
        // Only forward backfill samples that fill an actual gap.
        let realtimeLifeCounts = Set(recentSamples.map { $0.lifeCount })
        var newSamples: [NewGlucoseSample] = []
        var droppedDuplicates = 0
        for sample in page.samples {
            guard let mgdl = sample.glucoseMgDL else { continue }
            if realtimeLifeCounts.contains(sample.lifeCount) {
                droppedDuplicates += 1
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
        }
        if !newSamples.isEmpty {
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData(newSamples))
            }
            let firstDate = newSamples.first?.date.timeIntervalSince1970 ?? 0
            let lastDate = newSamples.last?.date.timeIntervalSince1970 ?? 0
            let values = newSamples.map { Int($0.quantity.doubleValue(for: .milligramsPerDeciliter)) }
            let suffix = droppedDuplicates > 0 ? " (dropped \(droppedDuplicates) realtime-duplicate sample(s))" : ""
            llog("forwarded \(newSamples.count) backfill samples to Loop: lifeCount \(page.startLifeCount)..\(page.endLifeCount), dates \(firstDate)..\(lastDate), mgdl=\(values)\(suffix)")
        } else if droppedDuplicates > 0 {
            llog("dropped all \(droppedDuplicates) backfill sample(s) in page lifeCount \(page.startLifeCount)..\(page.endLifeCount) — all overlap with realtime")
        }
        // Advance the watermark to the page's end, even if no usable samples
        // -- skipping unusable samples shouldn't cause us to re-request them.
        var updated = state
        let prior = updated.lastHistoricalLifeCount ?? 0
        if page.endLifeCount > prior {
            updated.lastHistoricalLifeCount = page.endLifeCount
            setState(updated)
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
                // Bracket the reconnect with a UIApplication background task so
                // iOS gives us the ~30s window needed to finish a BLE handshake
                // when this loop fires while the app is backgrounded. Without
                // this we get suspended mid-handshake and the await chain parks
                // indefinitely (verified in the 18:31→18:47 hang in field logs).
                await Self.withBackgroundTask(name: "LibreLoop.reconnect") {
                    await self.runReconnectOnce()
                }
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
                    phase5RawKey: phase5ToPersist
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
