import Foundation
import HealthKit
import LibreCRKit
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

    /// Computed lifecycle for UI consumption.
    public var sensorLifecycle: LibreLoopSensorLifecycle {
        LibreLoopSensorLifecycle.compute(
            sensorPaired: state.sensorSerial != nil,
            activatedAt: state.activatedAt,
            latestReadingAt: state.latestReadingTimestamp,
            firstActionableReadingAt: state.firstActionableReadingAt,
            lastPairedAt: state.lastPairedAt,
            hasLiveMonitor: monitor != nil
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
    /// Bluetooth row so failures are visible without diving into Console.app.
    /// Cleared on successful reconnect.
    public internal(set) var lastReconnectError: String? {
        didSet { notifyStateObservers() }
    }

    /// Wall-clock time of the most recent reconnect attempt (success or fail).
    /// Used together with `lastReconnectError` to show "Last attempt Xs ago".
    public internal(set) var lastReconnectAttemptAt: Date? {
        didSet { notifyStateObservers() }
    }

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
        var blank = state
        blank.receiverID = nil
        blank.sensorSerial = nil
        blank.bleAddress = nil
        blank.blePIN = nil
        blank.peripheralID = nil
        blank.activatedAt = nil
        blank.latestReadingTimestamp = nil
        blank.firstActionableReadingAt = nil
        blank.lastHistoricalLifeCount = nil
        blank.latestSample = nil
        blank.recentSamples = []
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
    public var glucoseDisplay: GlucoseDisplayable? { nil }

    // DeviceManager (tidepool-sync) surface for "the device is reachable
    // but we're not getting data right now" vs "the device is broken".
    public var inSignalLoss: Bool {
        guard state.sensorSerial != nil else { return false }
        return monitor == nil
    }
    public var isInoperable: Bool { false }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(hasValidSensorSession: state.sensorSerial != nil,
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

    private var noDataWatchdog: Task<Void, Never>?
    private var restorationTask: Task<Void, Never>?

    /// True once we've issued a backfill request for the current BLE session.
    /// Reset when the monitor is cleared so the next session re-requests.
    var hasRequestedBackfillThisSession: Bool = false

    /// Single long-lived BLE scanner. Created with
    /// CBCentralManagerOptionRestoreIdentifierKey so iOS can preserve the
    /// connected peripheral + subscriptions across app terminations and
    /// hand them back to us on relaunch via `restorationEvents()`. The same
    /// scanner is used for pair, reconnect, and ongoing monitoring -- the
    /// restoration identifier must stay stable for restoration to work.
    private static let restorationIdentifier = "org.loopkit.LibreLoop.central"
    public lazy var scanner: SensorScanner = {
        // Route BLE-layer per-step timing from the patched local LibreCRKit
        // checkout into our file logger. The fork-local BLETiming helper
        // doesn't exist in upstream LibreCRKit; if SwiftPM re-resolves the
        // package this call will fail to compile and we'll know to re-apply
        // the patch (or accept that the instrumentation is gone).
        BLETiming.setLogger { llog("ble: \($0)") }
        let scanner = SensorScanner(configuration: .background(restorationIdentifier: Self.restorationIdentifier))
        startRestorationListener(on: scanner)
        return scanner
    }()

    private func startRestorationListener(on scanner: SensorScanner) {
        restorationTask?.cancel()
        restorationTask = Task { [weak self] in
            for await event in scanner.restorationEvents() {
                guard let self else { return }
                await MainActor.run {
                    self.handleRestorationEvent(event)
                }
                if Task.isCancelled { break }
            }
        }
        // Tell iOS to wake us when our peripheral comes into range or
        // disconnects, so we don't have to actively scan to notice. Combined
        // with retrievePeripherals(withIdentifiers:) in reconnect, this
        // replaces the "scan forever and hope" model that gets throttled
        // after a few hours of failures.
        if let id = state.peripheralID {
            scanner.registerForConnectionEvents(peripheralIDs: [id])
            llog("registered for connection events on peripheral \(id.uuidString)")
        }
        startConnectionEventListener(on: scanner)
    }

    private var connectionEventTask: Task<Void, Never>?

    private func startConnectionEventListener(on scanner: SensorScanner) {
        connectionEventTask?.cancel()
        connectionEventTask = Task { [weak self] in
            for await event in scanner.connectionEvents() {
                guard let self else { return }
                llog("connection event: \(String(describing: event.event)) peripheral=\(event.peripheral.identifier.uuidString)")
                if event.peripheral.identifier == self.state.peripheralID {
                    await MainActor.run {
                        // Any event for our peripheral is a hint to attempt
                        // reconnect. Idempotent if loop is running.
                        self.scheduleInitialReconnect()
                    }
                }
                if Task.isCancelled { break }
            }
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
        scheduleInitialReconnect()
    }

    public init() {
        self.state = LibreLoopCGMManagerState()
        observeAppLifecycle()
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
        noDataWatchdog?.cancel()
        restorationTask?.cancel()
        connectionEventTask?.cancel()
    }

    /// Watchdog: if a monitor is alive but no glucose readings have arrived
    /// within the threshold, treat the session as silently dead and force a
    /// reconnect. Covers the case where BLE is technically "connected" but
    /// the link is no longer producing notifications (rare; Loop has
    /// bluetooth-central background mode so backgrounding alone doesn't
    /// trigger this).
    private static let noDataThreshold: TimeInterval = 3 * 60

    func startNoDataWatchdog() {
        noDataWatchdog?.cancel()
        noDataWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noDataThreshold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.monitor != nil else { return }
            // Only force reconnect if we still haven't seen a recent reading.
            let last = self.state.latestReadingTimestamp
            let stale = last.map { Date().timeIntervalSince($0) > Self.noDataThreshold } ?? true
            if stale {
                llog("no-data watchdog fired: \(Int(Self.noDataThreshold))s without a reading on a monitor we believe is connected; dropping monitor and re-arming reconnect")
                await MainActor.run {
                    self.monitor?.stop()
                    self.monitor = nil
                    // Setting monitor=nil alone doesn't start the reconnect
                    // loop; kick it off explicitly. Idempotent if a loop is
                    // already running.
                    self.scheduleInitialReconnect()
                }
            }
        }
    }

    func cancelNoDataWatchdog() {
        noDataWatchdog?.cancel()
        noDataWatchdog = nil
    }

    public required convenience init?(rawState: CGMManager.RawStateValue) {
        self.init()
        if let parsed = LibreLoopCGMManagerState(rawValue: rawState) {
            self.state = parsed
            // Repopulate in-memory recent samples from the persisted tail so
            // the settings UI has context immediately after relaunch.
            self.recentSamples = parsed.recentSamples
        }
        // Saved sensor state restored -> kick off a connect attempt so we
        // start receiving glucose without waiting for Loop's next poll.
        // Same disconnect path is reused; gated on having a saved blePIN.
        if state.blePIN != nil && state.sensorSerial != nil {
            // Touch the lazy scanner so its central manager is created
            // before iOS expects to deliver willRestoreState. The
            // restoration listener is wired in the scanner accessor.
            _ = scanner
            scheduleInitialReconnect()
        }
    }

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        // Glucose samples are delivered asynchronously via
        // `cgmManagerDelegate?.cgmManager(_, hasNew:)` from the BLE monitor,
        // so this poll-style API never has anything new to add. But Loop's
        // periodic calls are a useful nudge to keep the link healthy:
        //   - No monitor + saved state -> revive reconnect loop.
        //   - Monitor alive but readings stale -> the session is silently
        //     dead; drop the monitor so the disconnect path kicks in.
        let needsRevive = monitor == nil && state.blePIN != nil
        let isStalled: Bool
        if monitor != nil,
           let last = state.latestReadingTimestamp,
           Date().timeIntervalSince(last) > Self.noDataThreshold {
            isStalled = true
        } else {
            isStalled = false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if needsRevive {
                self.scheduleInitialReconnect()
            } else if isStalled {
                self.monitor?.stop()
                self.monitor = nil
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

    public func delete(completion: @escaping () -> Void) {
        completion()
    }
}
