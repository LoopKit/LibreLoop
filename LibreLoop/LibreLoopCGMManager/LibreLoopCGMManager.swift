import Foundation
import HealthKit
import LibreCRKit
import LoopAlgorithm
import LoopKit
import os.log
import UIKit


public final class LibreLoopCGMManager: CGMManager {
    public static let pluginIdentifier = "LibreLoopCGMManager"
    public static let localizedTitle = "FreeStyle Libre 3"
    public static let healthKitStorageDelay: TimeInterval = 0

    public var localizedTitle: String { Self.localizedTitle }

    // Pluggable in tidepool-sync's LoopKit dropped the static pluginIdentifier
    // in favor of an instance var, and added markAsDepedency.
    public var pluginIdentifier: String { Self.pluginIdentifier }
    public func markAsDepedency(_ isDependency: Bool) {}

    public weak var cgmManagerDelegate: CGMManagerDelegate?
    public var delegateQueue: DispatchQueue!

    public internal(set) var state: LibreLoopCGMManagerState
    public var rawState: CGMManager.RawStateValue { state.rawValue }

    /// Live sensor monitor adopted after a successful pairing. nil before
    /// pairing or after the BLE session has dropped.
    var monitor: LibreLoopSensorMonitor? {
        didSet { notifyStateObservers() }
    }

    /// Wall-clock time the current BLE session was adopted. Non-nil only
    /// while `monitor` is alive. Used by the UI to surface the
    /// connected-but-mute case ("connected for X, but no data received") --
    /// the only place a healthy link with no readings should ever show up,
    /// and only if the sensor firmware glitches. Cleared on disconnect.
    public internal(set) var connectedAt: Date? {
        didSet { notifyStateObservers() }
    }

    /// Single-flight reconnect attempt. Non-nil while a `central.connect`+
    /// handshake is in progress. Cleared on attempt completion. Retries
    /// are driven by CoreBluetooth callbacks (didDisconnect / state
    /// changes), not by a polling loop -- if an attempt finishes without
    /// adopting a monitor, the completion handler asks CB to tear down
    /// the link, which fires didDisconnect, which schedules the next
    /// attempt. CB itself handles the wait-for-reachability.
    var reconnectAttempt: Task<Void, Never>?
    /// Set once the CGM has been deleted. The BLE central is now shared across
    /// manager lifetimes, so a deleted manager must stop driving it — otherwise
    /// its reconnect loop re-establishes a session that collides with the
    /// manager that replaces it (a re-add), producing PairingFlowError 7 during
    /// the new pairing's handshake. Guards reconnect scheduling.
    private(set) var isDeleted = false

    /// Alert identifier for the sensor-attention alert (replace/ended), routed
    /// through LoopKit's AlertManager. Separate from the scheduled expiry alerts.
    static let sensorAttentionAlertID: Alert.AlertIdentifier = "sensorAttention"
    /// Last sensor-attention state we acted on, so the per-minute patch-status
    /// stream only alerts on an actual state change (not every minute).
    var lastSensorAttention: Libre3SensorAttention?
    /// Wall-clock time we last spawned a reconnect Task. Used by
    /// scheduleReconnect to coalesce bursts of CB events (e.g., a
    /// flapping link can emit 4+ didDisconnect / didFailToConnect
    /// events within 100ms) into a single attempt -- without this we'd
    /// rapidly cancel and respawn Tasks for every event in the burst.
    var lastReconnectAttemptStartedAt: Date?
    /// Minimum wall-clock interval between consecutive reconnect
    /// attempts. CB's central.connect is idempotent on its own side, so
    /// our rapid re-calls weren't helping iOS reconnect any faster -- they
    /// were just churning Task lifecycle and the BLE stack.
    static let minReconnectInterval: TimeInterval = 0.5

    /// How long a live link may stay silent before we treat the sensor as
    /// mute and force a disconnect to recover (see `isConnectedButMute`).
    static let muteForceDisconnectInterval: TimeInterval = 11 * 60

    /// Pure BLE connection state. Does NOT incorporate data-freshness
    /// signals; those belong in the lifecycle bar / Last Reading card so
    /// this row reflects only Layer 2 reality.
    public var connectionStatus: ConnectionStatus {
        guard state.sensorSerial != nil else { return .notPaired }
        if monitor != nil {
            // We may not have received the first reading yet; that's still a
            // valid "connected" state at the BLE layer.
            return .connected
        }
        return isReconnecting ? .reconnecting : .disconnected
    }

    public enum ConnectionStatus: Equatable {
        case notPaired
        case connecting
        case connected
        case reconnecting
        case disconnected
    }

    /// Most recent glucose sample. Snapshot-restored from rawState at init
    /// so the Last Reading card stays populated across app kills; updated
    /// in `recordSample` as new readings arrive.
    public var latestSample: LibreLoopGlucoseSample? {
        get { state.latestSample }
    }

    /// Ring buffer of recently received samples, newest first.
    /// In-memory list is capped at 100 for the "Recent Readings" table;
    /// the rawState-persisted subset is shorter (see
    /// LibreLoopCGMManagerState.recentSamplesPersistenceCap).
    public private(set) var recentSamples: [LibreLoopGlucoseSample] = []
    private static let recentSamplesCap = 100

    // MARK: - Debug stream capture (in-memory only, for the Glucose Streams view)
    //
    // Captured raw so the developer debug view can compare per-minute noise.
    // Main-queue isolated: written from the capture helpers below (which dispatch
    // to main) and read by the debug view model on main. Never persisted.
    private static let debugStreamCap = 720   // ~12 h of per-minute records
    public private(set) var recentClinicalStream: [LibreLoopClinicalStreamSample] = []
    public private(set) var recentEmbeddedHistorical: [LibreLoopEmbeddedHistoricalSample] = []
    /// Newest-first log of every decoded read for the developer read inspector.
    public private(set) var recentReads: [LibreLoopStreamReadRecord] = []
    private static let debugReadsCap = 300

    func captureRead(_ record: LibreLoopStreamReadRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentReads.insert(record, at: 0)
            let overflow = self.recentReads.count - Self.debugReadsCap
            if overflow > 0 { self.recentReads.removeLast(overflow) }
        }
    }

    func captureClinicalStream(_ record: ClinicalReadingRecord) {
        let sample = LibreLoopClinicalStreamSample(
            date: Date(),
            lifeCount: record.lifeCount,
            currentMgDL: record.currentGlucoseMgDL.map(Double.init),
            rawWord1: record.rawSensorWord1,
            rawWord2: record.rawSensorWord2,
            rawWord3: record.rawSensorWord3
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentClinicalStream.append(sample)
            let overflow = self.recentClinicalStream.count - Self.debugStreamCap
            if overflow > 0 { self.recentClinicalStream.removeFirst(overflow) }
        }
    }

    func captureEmbeddedHistorical(lifeCount: UInt16, mgdl: UInt16) {
        let sample = LibreLoopEmbeddedHistoricalSample(date: Date(), lifeCount: lifeCount, mgdl: Double(mgdl))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The same finalized point repeats across ~5 realtime frames before
            // historicalLifeCount advances; keep one entry per boundary.
            if self.recentEmbeddedHistorical.last?.lifeCount == lifeCount { return }
            self.recentEmbeddedHistorical.append(sample)
            let overflow = self.recentEmbeddedHistorical.count - Self.debugStreamCap
            if overflow > 0 { self.recentEmbeddedHistorical.removeFirst(overflow) }
        }
    }

    /// Computed lifecycle for UI consumption.
    public var sensorLifecycle: LibreLoopSensorLifecycle {
        LibreLoopSensorLifecycle.compute(
            sensorPaired: state.sensorSerial != nil,
            activatedAt: state.activatedAt,
            latestReadingAt: state.latestReadingTimestamp,
            firstReadingAt: state.firstReadingAt,
            lastPairedAt: state.lastPairedAt,
            hasLiveMonitor: monitor != nil,
            wearDurationMinutes: state.wearDurationMinutes,
            warmupDurationMinutes: state.warmupDurationMinutes
        )
    }

    let stateObservers = LibreLoopWeakObserverSet<LibreLoopStateObserver>()

    /// Short human-readable phase string (e.g. "Searching for sensor",
    /// "Authenticating", "Refreshing notifications", "Waiting for first
    /// reading"). UI shows this under the Bluetooth row so the user sees
    /// progress rather than a generic "Connecting…".
    public internal(set) var statusDetail: String? {
        didSet { notifyStateObservers() }
    }

    func updateStatusDetail(_ text: String?) {
        if Thread.isMainThread {
            self.statusDetail = text
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusDetail = text
            }
        }
    }

    /// True when a reconnect Task is either sleeping before the next attempt
    /// or actively scanning/handshaking. Drives the "Reconnecting..." status
    /// in the UI so the user can see we're working on it rather than seeing
    /// a bare "Disconnected" with no recourse.
    var isReconnecting: Bool = false {
        didSet { notifyStateObservers() }
    }

    /// Last reconnect-attempt failure message, surfaced in the UI under the
    /// Bluetooth row so persistent failures are visible without diving into
    /// Console.app. Set only after the reconnect loop has failed
    /// consistently -- transient single-attempt failures don't flash UI
    /// because the link usually recovers on the next attempt. Cleared on
    /// successful reconnect.
    public internal(set) var lastReconnectError: String? {
        didSet { notifyStateObservers() }
    }

    /// Wall-clock time of the most recent reconnect attempt (success or fail).
    /// Used together with `lastReconnectError` to show "Last attempt Xs ago".
    public internal(set) var lastReconnectAttemptAt: Date? {
        didSet { notifyStateObservers() }
    }

    /// Number of reconnect attempts that have failed since the last success.
    /// Resets to 0 on each successful reconnect. Used to gate UI display of
    /// `lastReconnectError` -- field experience shows ~30-50% of cached
    /// reconnects fail phase 6 verification and the next attempt succeeds,
    /// so a single failure isn't worth alarming the user about.
    var consecutiveReconnectFailures: Int = 0
    /// Wall-clock time of the first failure in the current consecutive run.
    /// Nil when no failures since last success. Used as a time-based gate
    /// (in addition to count) so the error surfaces if the loop has been
    /// down for a while even if attempts are infrequent.
    var consecutiveReconnectFailuresStartedAt: Date?

    /// How many consecutive reconnect failures, OR how long the failure run
    /// must persist, before we surface the error in the UI. Tuned so a
    /// single phase 6 verification failure that recovers on retry stays
    /// silent.
    static let reconnectErrorDisplayThresholdCount = 3
    static let reconnectErrorDisplayThresholdInterval: TimeInterval = 2 * 60

    func recordSample(_ sample: LibreLoopGlucoseSample) {
        recentSamples.insert(sample, at: 0)
        if recentSamples.count > Self.recentSamplesCap {
            recentSamples.removeLast(recentSamples.count - Self.recentSamplesCap)
        }
        // Mirror the sample (and a trimmed tail) into rawState so the next
        // app launch can repopulate the Last Reading card immediately.
        var updated = state
        updated.latestSample = sample
        updated.recentSamples = Array(recentSamples.prefix(LibreLoopCGMManagerState.recentSamplesPersistenceCap))
        setState(updated)
    }

    /// Update the most recently recorded sample with its forwarding
    /// outcome (sent vs throttled vs non-actionable). Matched by
    /// lifeCount, which is unique within a sensor session. No-op if the
    /// sample isn't in `recentSamples` (shouldn't happen — `recordSample`
    /// runs immediately before this).
    func recordForwardingOutcome(
        forLifeCount lifeCount: UInt16,
        wasForwarded: Bool,
        skipReason: String?
    ) {
        guard let idx = recentSamples.firstIndex(where: { $0.lifeCount == lifeCount }) else { return }
        let updatedSample = recentSamples[idx].withForwardingOutcome(
            wasForwarded: wasForwarded,
            skipReason: skipReason
        )
        recentSamples[idx] = updatedSample
        var updated = state
        if state.latestSample?.lifeCount == lifeCount {
            updated.latestSample = updatedSample
        }
        updated.recentSamples = Array(recentSamples.prefix(LibreLoopCGMManagerState.recentSamplesPersistenceCap))
        setState(updated)
    }

    /// Wipe everything sensor-specific so the user can pair a new sensor while
    /// keeping the CGM configured with Loop. Stops the BLE monitor, kills the
    /// reconnect loop, clears in-memory samples, and zeros the per-sensor
    /// fields of rawState (serial, blePIN, receiverID, peripheralID,
    /// bleAddress, activatedAt, latestReadingTimestamp).
    ///
    /// Session keys for the discarded sensor stay in Keychain (we never
    /// delete other apps' keys); on Keychain reuse, the new sensor's keys
    /// overwrite the entry keyed by the new serial.
    public func discardSensor() {
        cancelReconnect()
        monitor?.stop()
        monitor = nil
        isReconnecting = false
        recentSamples = []
        retractExpiryAlerts()
        // Emit .sensorEnd before we blank state so the event's
        // deviceIdentifier still resolves to the session that's ending.
        // Matches the .sensorStart we emitted at pairing time so Loop's
        // CgmEventStore has a clean session boundary.
        if let serial = state.sensorSerial {
            let identifier = Self.deviceIdentifier(serial: serial, receiverID: state.receiverID)
            let event = PersistedCgmEvent(
                date: Date(),
                type: .sensorEnd,
                deviceIdentifier: identifier
            )
            llog("emitting CgmEvent .sensorEnd deviceIdentifier=\(identifier)")
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: [event])
            }
        }
        var blank = state
        blank.receiverID = nil
        blank.sensorSerial = nil
        blank.bleAddress = nil
        blank.blePIN = nil
        blank.peripheralID = nil
        blank.activatedAt = nil
        blank.latestReadingTimestamp = nil
        blank.firstReadingAt = nil
        blank.lastHistoricalLifeCount = nil
        blank.latestSample = nil
        blank.recentSamples = []
        blank.expiryAlertsScheduledForActivatedAt = nil
        setState(blank)
    }

    /// Toggle the experimental minute-by-minute forwarding mode. UI must
    /// only call this with `enabled: true` after the user has acknowledged
    /// the dosing-cadence warning sheet — see LibreLoopUI.
    public func setExperimentalMinuteByMinuteForwarding(_ enabled: Bool) {
        var updated = state
        updated.experimentalMinuteByMinuteForwarding = enabled
        setState(updated)
    }

    public let isOnboarded = true

    public var appURL: URL? { nil }
    public var providesBLEHeartbeat: Bool { true }
    public var shouldSyncToRemoteService: Bool { true }
    public var managedDataInterval: TimeInterval? { nil }
    public var glucoseDisplay: GlucoseDisplayable? {
        guard let sample = state.latestSample else { return nil }
        return LibreLoopGlucoseDisplay(sample: sample)
    }

    // DeviceManager (tidepool-sync) surface for "the device is reachable
    // but we're not getting data right now" vs "the device is broken".
    public var inSignalLoss: Bool {
        guard state.sensorSerial != nil else { return false }
        return monitor == nil
    }
    public var isInoperable: Bool { false }

    public var cgmManagerStatus: CGMManagerStatus {
        let lifecycle = sensorLifecycle
        let inWarmup: Bool
        switch lifecycle {
        case .warmup, .pairingWarmup: inWarmup = true
        default: inWarmup = false
        }
        return CGMManagerStatus(hasValidSensorSession: state.sensorSerial != nil,
                                inSensorWarmup: inWarmup,
                                lastCommunicationDate: state.latestReadingTimestamp,
                                device: device)
    }

    public var device: HKDevice? {
        HKDevice(name: "FreeStyle Libre 3",
                 manufacturer: "Abbott",
                 model: "Libre 3",
                 hardwareVersion: nil,
                 firmwareVersion: nil,
                 softwareVersion: nil,
                 localIdentifier: state.sensorSerial,
                 udiDeviceIdentifier: nil)
    }

    public var debugDescription: String {
        """
        ## LibreLoopCGMManager
        * sensorSerial: \(state.sensorSerial ?? "nil")
        * activatedAt: \(String(describing: state.activatedAt))
        * latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))
        """
    }

    /// True once we've issued a backfill request for the current BLE session.
    /// Reset when the monitor is cleared so the next session re-requests.
    var hasRequestedBackfillThisSession: Bool = false

    /// Set of lifeCounts we've forwarded as backfill (historical or clinical)
    /// during the current BLE session. Used to suppress clinical samples that
    /// overlap historical and vice versa, on top of the realtime-overlap
    /// suppression done against `recentSamples`. Reset whenever the monitor
    /// is adopted fresh (see `adopt`).
    var backfillForwardedLifeCounts: Set<UInt16> = []

    /// Wall-clock timestamp of the most recent historical backfill page we
    /// received this session. Used by the post-historical clinical request
    /// to wait for the historical stream to drain before writing the
    /// clinical command — issuing patchControl while the sensor is still
    /// responding to the previous command produces an ATT writeFailed
    /// "Unknown ATT error".
    var lastHistoricalPageAt: Date?

    /// Single long-lived BLE scanner. Created with
    /// CBCentralManagerOptionRestoreIdentifierKey so iOS can preserve the
    /// connected peripheral + subscriptions across app terminations and
    /// hand them back to us on relaunch via `restorationEvents()`. The same
    /// scanner is used for pair, reconnect, and ongoing monitoring -- the
    /// restoration identifier must stay stable for restoration to work.
    private static let restorationIdentifier = "org.loopkit.LibreLoop.central"

    /// One process-wide BLE central, shared across CGMManager lifetimes.
    ///
    /// A CBCentralManager created with a state-restoration identifier is retained
    /// by the system for the whole app lifetime (so iOS can relaunch us on BLE
    /// events). Creating a SECOND central with the same restoration identifier —
    /// which is exactly what happened when the CGM was deleted and re-added in
    /// the same app session — is a CoreBluetooth API misuse: the new central
    /// never powers on, surfacing as "Bluetooth not available" during pairing.
    /// Sharing one instance avoids the collision. It's created lazily on first
    /// use (so we don't trigger the Bluetooth permission prompt before the user
    /// starts pairing) and outlives individual managers; each manager attaches
    /// its own event listener and tears it down again in delete()/deinit.
    private static let sharedScanner: SensorScannerNG = {
        BLETiming.setLogger { llog("ble: \($0)") }
        return SensorScannerNG(configuration: .background(restorationIdentifier: restorationIdentifier))
    }()

    public lazy var scanner: SensorScannerNG = {
        let scanner = Self.sharedScanner
        // Tell iOS to wake us when our peripheral comes into range or
        // disconnects so we don't have to actively scan to notice.
        if let id = state.peripheralID {
            scanner.registerForConnectionEvents(peripheralIDs: [id])
            llog("registered for connection events on peripheral \(id.uuidString)")
        }
        startEventListener(on: scanner)
        return scanner
    }()

    private var eventListenerTask: Task<Void, Never>?

    /// Single Task that consumes `scanner.events()` and routes each CB
    /// event to the right reaction. Replaces the three separate
    /// listener Tasks the old SensorScanner exposed (state /
    /// connection-event / restoration), all unified now that the new
    /// scanner emits one event stream.
    private func startEventListener(on scanner: SensorScannerNG) {
        eventListenerTask?.cancel()
        eventListenerTask = Task { [weak self] in
            for await event in scanner.events() {
                guard let self else { return }
                await MainActor.run { self.handleScannerEvent(event) }
                if Task.isCancelled { break }
            }
        }
    }

    @MainActor
    private func handleScannerEvent(_ event: SensorScannerNG.Event) {
        switch event {
        case .stateChanged(let s):
            llog("central state: \(s.rawValue)")
            // Mirrors G7's centralManagerDidUpdateState behavior: when
            // BT comes back on (airplane mode toggle, system reset
            // settled, etc.), kick a reconnect if we have saved state.
            if s == .poweredOn, self.state.peripheralID != nil, self.monitor == nil {
                self.scheduleReconnect()
            }
        case .didConnect(let p):
            llog("ble: didConnect \(p.identifier.uuidString)")
            // didConnect is exactly the moment to spawn the handshake
            // -- bypass the burst-debounce window so a peripheral that
            // pops back into range mid-debounce doesn't sit connected
            // with nothing driving the handshake. Skip entirely if a
            // handshake Task is already in flight: the in-flight Task
            // is using connectAndBuildSession which observes its own
            // events stream, and calling scheduleReconnect again here
            // is pure noise (and historically participated in a
            // central.connect re-fire loop during the handshake
            // window).
            if p.identifier == self.state.peripheralID, self.reconnectAttempt == nil {
                self.lastReconnectAttemptStartedAt = nil
                self.scheduleReconnect()
            }
        case .didFailToConnect(let p, let err):
            llog("ble: didFailToConnect \(p.identifier.uuidString) error=\(err?.localizedDescription ?? "nil")")
            // Event-driven, like G7's didFailToConnect: don't cancel
            // anything, just re-arm. scheduleReconnect re-arms the CB
            // connect intent and, via its reconnectAttempt single-flight
            // guard, won't spawn a duplicate while a handshake is in
            // flight. A failed connect means no session was built, so
            // there's nothing in flight to unwind anyway.
            if p.identifier == self.state.peripheralID {
                self.scheduleReconnect()
            }
        case .didDisconnect(let p, let err):
            llog("ble: didDisconnect \(p.identifier.uuidString) error=\(err?.localizedDescription ?? "nil")")
            // Don't cancel the in-flight handshake Task. Cancelling only
            // the wrapper Task left LibreLoopPairingService.reconnect()
            // running (it isn't cancellation-aware) AND cleared the
            // single-flight guard -- so a second attempt raced the first,
            // and the "cancelled" one fell through to a full first-pair
            // handshake (StartAuthentication 0x01) that knocked the live
            // session off and produced PairingFlowError 7 + a ~30-min
            // stall (field log 2026-06-04 13:38). Instead, let the
            // disconnect itself unwind the attempt: the session's pending
            // BLE ops throw when the peer drops (sessionBox watchdog), so
            // the handshake await fails promptly on its own. We just
            // re-arm the connect intent.
            if p.identifier == self.state.peripheralID {
                // A CB-level disconnect is the authoritative "link is dead"
                // signal. The monitor's own disconnect detection keys off
                // session.notifications() terminating, but a "connection timed
                // out" leaves that stream silently stalled rather than ended
                // (field log 2026-06-04 18:53: link timed out, monitor stayed
                // non-nil, scheduleReconnect's `guard monitor == nil` no-op'd
                // every retry, 7+ min outage). So when we still hold a monitor,
                // tear it down here -- handleMonitorDisconnect clears it and
                // re-arms reconnect. When monitor is nil (handshake in flight),
                // a bare scheduleReconnect is correct and must not disturb it.
                if self.monitor != nil {
                    self.handleMonitorDisconnect()
                } else {
                    self.scheduleReconnect()
                }
            }
        case .connectionEvent(let e, let p):
            llog("connection event: \(e.rawValue) peripheral=\(p.identifier.uuidString)")
            if p.identifier == self.state.peripheralID {
                if e == .peerDisconnected, self.monitor != nil {
                    self.handleMonitorDisconnect()
                } else {
                    self.scheduleReconnect()
                }
            }
        case .willRestoreState(let r):
            self.handleRestorationEvent(r)
        case .didDiscover:
            // Discoveries are consumed by the pair-time scan inside
            // LibreLoopPairingService via its own events() subscription.
            // The CGMManager doesn't drive scans, so ignore here.
            break
        }
    }

    private func handleRestorationEvent(_ event: SensorRestorationEvent) {
        llog("BLE restoration event: \(event.peripherals.count) peripheral(s)")
        guard let expected = state.peripheralID else {
            llog("BLE restoration: no saved peripheralID, ignoring")
            return
        }
        guard let restored = event.peripherals.first(where: { $0.identifier == expected }) else {
            llog("BLE restoration: saved peripheral not in restored set")
            return
        }
        llog("BLE restoration: matched \(restored.identifier.uuidString); scheduling reconnect")
        // We have a CBPeripheral handle from iOS that may already be
        // connected. Easiest path: drop into the same reconnect loop --
        // it'll see the peripheral via scan (or CB short-circuit because
        // it's already known) and run the handshake.
        scheduleReconnect()
    }

    public init() {
        self.state = LibreLoopCGMManagerState()
        observeAppLifecycle()
        registerDeviceLogForwarding()
    }

    /// Mirror every `llog` line into Loop's persistent DeviceLog so LibreLoop's
    /// connection/data/error events show up in Loop's device logs and Issue
    /// Reports, like the other CGM managers. The entry type is inferred from
    /// the message; the device identifier is the sensor serial.
    private func registerDeviceLogForwarding() {
        setLibreLoopDeviceLogSink { [weak self] message in
            guard let self else { return }
            let lower = message.lowercased()
            let type: DeviceLogEntryType
            if lower.contains("error") || lower.contains("fail") {
                type = .error
            } else if lower.contains("connect") || lower.contains("disconnect") {
                type = .connection
            } else {
                type = .receive
            }
            let identifier = self.state.sensorSerial
            let forward = { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: identifier, type: type, message: message, completion: nil)
            }
            if let queue = self.delegateQueue {
                queue.async(execute: forward)
            } else {
                forward()
            }
        }
    }

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "protectedDataWillBecomeUnavailable"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "protectedDataDidBecomeAvailable"),
        ]
        for (name, label) in names {
            nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                llog("app lifecycle: \(label) (monitor=\(self.monitor != nil ? "alive" : "nil"), reconnecting=\(self.isReconnecting), latestReading=\(self.state.latestReadingTimestamp.map { Int(Date().timeIntervalSince($0)) }.map { "\($0)s ago" } ?? "never"))")
            }
        }
    }

    deinit {
        eventListenerTask?.cancel()
    }

    public required convenience init?(rawState: CGMManager.RawStateValue) {
        self.init()
        if let parsed = LibreLoopCGMManagerState(rawValue: rawState) {
            self.state = parsed
            // Repopulate in-memory recent samples from the persisted tail so
            // the settings UI has context immediately after relaunch.
            self.recentSamples = parsed.recentSamples
            // Migrate an already-paired sensor's receiverID into the stable
            // app-wide Keychain key (introduced in this version) if it isn't
            // there yet. This preserves the existing identity AND makes it
            // survive a future plugin remove/re-add without re-pairing. Only
            // seeds when the app-wide key is empty — never overwrites it.
            if let rid = Self.receiverIDFromState(parsed.receiverID),
               LibreLoopKeychain.loadAppReceiverID() == nil {
                LibreLoopKeychain.saveAppReceiverID(rid)
            }
        }
        // Saved sensor state restored -> kick off a connect attempt so we
        // start receiving glucose without waiting for Loop's next poll.
        // Same disconnect path is reused; gated on having a saved blePIN.
        if state.blePIN != nil && state.sensorSerial != nil {
            // Touch the lazy scanner so its central manager is created
            // before iOS expects to deliver willRestoreState. The
            // restoration listener is wired in the scanner accessor.
            _ = scanner
            scheduleReconnect()
        }
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        // Glucose samples are delivered asynchronously via
        // `cgmManagerDelegate?.cgmManager(_, hasNew:)` from the BLE monitor,
        // so this poll-style API never has anything new to add. The system is
        // CoreBluetooth-driven: connection/data come from CB callbacks, not
        // from polling here. But Loop's periodic call is our reliable
        // "we got runtime" hook, so we use it for two idempotent checks:
        //   1. No live monitor but saved state -> re-arm the CB connect
        //      intent (belt-and-suspenders if a transition left us with no
        //      standing intent).
        //   2. Live link but mute for >11 min -> the sensor has gone silent
        //      while the BLE link stays up (a firmware glitch CB can't
        //      detect). Force a disconnect; the didDisconnect event drives
        //      scheduleReconnect, so recovery is fully automatic.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.monitor == nil, self.state.blePIN != nil {
                self.scheduleReconnect()
            } else if self.isConnectedButMute {
                self.forceDisconnectForMuteRecovery()
            }
        }
        completion(.noData)
    }

    // AlertResponder. Tidepool-sync's LoopKit replaced the completion-handler
    // signature with async/throws.
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws {}

    // AlertSoundVendor.
    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    private let statusObservers = WeakSynchronizedSet<CGMManagerStatusObserver>()

    public func addStatusObserver(_ observer: CGMManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: CGMManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    /// Push the current `cgmManagerStatus` to every observer. Used during
    /// warmup to keep the HUD progress bar updating once per minute --
    /// otherwise the HUD only refreshes on Loop's 5-min cycle and the
    /// progress bar visibly lags wall clock by up to 5 minutes.
    func notifyStatusObservers() {
        let status = cgmManagerStatus
        statusObservers.forEach { observer in
            observer.cgmManager(self, didUpdate: status)
        }
    }

    public func delete(completion: @escaping () -> Void) {
        // The central is shared and outlives this manager, so a deleted manager
        // must stop driving it — otherwise its event listener + reconnect loop
        // keep issuing connect/scan on the shared central and fight whatever
        // manager replaces it (e.g. a re-add). Cancel our reconnect, drop our
        // listener, and release any link/scan we started.
        // Set first so the disconnect we trigger below (and any in-flight CB
        // callback) can't re-arm a reconnect via handleMonitorDisconnect /
        // scheduleReconnect.
        isDeleted = true
        cancelReconnect()
        // A non-nil listener task means the lazy `scanner` was initialized, so
        // it's safe to touch without forcing central creation on a never-paired
        // manager being deleted.
        let scannerWasInitialized = eventListenerTask != nil
        eventListenerTask?.cancel()
        eventListenerTask = nil
        // Drop the live monitor and its BLE link so no session of ours lingers
        // on the shared central to collide with a future re-add's handshake.
        monitor = nil
        if scannerWasInitialized {
            scanner.stopScan()
            if let id = state.peripheralID,
               let peripheral = scanner.retrievePeripherals(withIdentifiers: [id]).first {
                scanner.cancelConnection(peripheral)
            }
        }
        completion()
    }
}

// MARK: - GlucoseDisplayable

struct LibreLoopGlucoseDisplay: GlucoseDisplayable {
    let sample: LibreLoopGlucoseSample

    var isStateValid: Bool { sample.isActionable }
    var isLocal: Bool { true }
    var glucoseRangeCategory: GlucoseRangeCategory? { nil }

    var trendType: GlucoseTrend? { Self.mapTrend(sample.trend) }

    static func mapTrend(_ trend: LibreLoopGlucoseSample.Trend) -> GlucoseTrend? {
        switch trend {
        case .notDetermined:  return nil
        case .fallingQuickly: return .downDown
        case .falling:        return .down
        case .stable:         return .flat
        case .rising:         return .up
        case .risingQuickly:  return .upUp
        }
    }

    var trendRate: LoopQuantity? {
        sample.rateOfChangeMgDLPerMinute.map {
            LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
        }
    }
}
