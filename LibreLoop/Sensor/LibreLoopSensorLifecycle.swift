import Foundation

/// Computed sensor lifecycle state for the FreeStyle Libre 3.
public enum LibreLoopSensorLifecycle: Equatable {
    case noSensor
    /// Sensor is paired but we haven't received the first glucose reading
    /// yet, so we can't compute activatedAt or lifecycle phase. Cleared as
    /// soon as the first sample arrives.
    case initializing
    /// Time-bounded initial warmup, immediately after sensor activation
    /// (first 60 min). We know the remaining time precisely.
    case warmup(progress: Double, remaining: TimeInterval)
    /// Switch-receiver / post-pair stabilization. The sensor flags readings
    /// not-actionable for a duration we can't predict precisely yet, so we
    /// anchor display on time since pair rather than a fake countdown.
    case pairingWarmup(pairedAt: Date)
    /// remaining: time left until expiry; total: sensor's full rated wear duration
    case active(remaining: TimeInterval, total: TimeInterval)
    /// End of life: either the wear clock reached the sensor's rated duration,
    /// or the sensor self-reported `sensorEnded`. Needs replacement, but is a
    /// normal outcome (shown as "Expired", not a failure).
    case expired
    case signalLost(since: Date)
    /// Sensor self-reported an early replace/error state (patchState 7 /
    /// `replaceSensor`) before reaching end of life. Authoritative and overrides
    /// timing-based phases — the sensor will not produce glucose again and must
    /// be replaced. A normal end-of-life reports `.expired`, not `.failed`.
    case failed

    /// Libre 3 spec default wear duration (14 days). Used when the sensor
    /// has not yet reported its own duration (e.g. legacy persisted state).
    public static let activeDuration: TimeInterval = 14 * 24 * 60 * 60
    /// Spec warmup duration (60 min). The Libre 3 family does not report
    /// a sensor-specific warmup duration; this constant applies to all variants.
    public static let warmupDuration: TimeInterval = 60 * 60
    private static let signalLostThreshold: TimeInterval = 6 * 60      // 6 minutes without a reading

    public static func compute(
        sensorPaired: Bool,
        activatedAt: Date?,
        latestReadingAt: Date?,
        firstReadingAt: Date?,
        lastPairedAt: Date?,
        hasLiveMonitor: Bool,
        wearDurationMinutes: Int? = nil,
        warmupDurationMinutes: Int? = nil,
        needsReplacement: Bool = false,
        endedNormally: Bool = false,
        now: Date = Date()
    ) -> LibreLoopSensorLifecycle {
        guard sensorPaired else { return .noSensor }

        let sensorWearDuration: TimeInterval = wearDurationMinutes
            .map { TimeInterval($0) * 60 }
            ?? activeDuration

        // A sensor-reported replace/ended state is authoritative — it overrides
        // every timing-based phase (it won't resume on its own). Distinguish a
        // normal end-of-life from an early failure so the UI shows "Expired" vs
        // "Sensor failed"; both require replacement.
        if needsReplacement {
            if endedNormally { return .expired }
            // A replace/terminated report from a sensor that has already reached
            // its rated wear duration is a normal end-of-life ("Expired"), not a
            // failure: some sensors emit the terminated-shutdown code (errorData
            // 8 → `replaceSensor`) after a clean end-of-wear. Only a
            // `replaceSensor` *before* rated wear is a genuine "Sensor failed".
            if let activatedAt, now.timeIntervalSince(activatedAt) >= sensorWearDuration {
                return .expired
            }
            return .failed
        }
        guard let activatedAt else { return .initializing }
        let age = now.timeIntervalSince(activatedAt)

        let sensorWarmupDuration: TimeInterval = warmupDurationMinutes
            .map { TimeInterval($0) * 60 }
            ?? warmupDuration

        if age >= sensorWearDuration {
            return .expired
        }
        // True initial warmup -- the sensor's own reported warmup window
        // from NFC patch info, falling back to the 60-min spec default.
        if age < sensorWarmupDuration {
            return .warmup(progress: age / sensorWarmupDuration, remaining: sensorWarmupDuration - age)
        }
        // Post-pair stabilization: we know warmup is done by wall clock
        // but we haven't received any reading yet (first reading post-
        // pair lands within ~1 min over BLE). As soon as that arrives
        // we treat the sensor as active; per-reading actionability is
        // surfaced via the forwarded sample's isDisplayOnly flag.
        if firstReadingAt == nil {
            return .pairingWarmup(pairedAt: lastPairedAt ?? now)
        }
        let stale = latestReadingAt.map { now.timeIntervalSince($0) > signalLostThreshold } ?? !hasLiveMonitor
        if stale {
            return .signalLost(since: latestReadingAt ?? activatedAt)
        }
        return .active(remaining: sensorWearDuration - age, total: sensorWearDuration)
    }

    public var displayName: String {
        switch self {
        case .noSensor:       return LocalizedString("No sensor", comment: "Sensor lifecycle: no sensor paired")
        case .initializing:   return LocalizedString("Initializing", comment: "Sensor lifecycle: initializing")
        case .warmup:         return LocalizedString("Warming up", comment: "Sensor lifecycle: warming up")
        // Distinct from .warmup: initial wall-clock warmup is complete but
        // the sensor is still flagging readings as not-actionable. "Warming
        // up" here is confusing past the 60-min mark.
        case .pairingWarmup:  return LocalizedString("Stabilizing", comment: "Sensor lifecycle: stabilizing after pairing")
        case .active:         return LocalizedString("Active", comment: "Sensor lifecycle: active")
        case .expired:        return LocalizedString("Expired", comment: "Sensor lifecycle: expired")
        case .signalLost:     return LocalizedString("Signal loss", comment: "Sensor lifecycle: signal loss")
        case .failed:         return LocalizedString("Sensor failed", comment: "Sensor lifecycle title: sensor failed (detail says replace)")
        }
    }
}

/// Module-scoped localization for the core LibreLoop module: looks strings up in
/// the plugin's own bundle rather than the host app's global table (mirrors
/// G7SensorKit's LocalizedString). Internal, so it doesn't collide with
/// LibreLoopUI's same-named helper.
func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    let bundle = Bundle(for: LibreLoopCGMManager.self)
    if let value = value {
        return NSLocalizedString(key, tableName: tableName, bundle: bundle, value: value, comment: comment)
    }
    return NSLocalizedString(key, tableName: tableName, bundle: bundle, comment: comment)
}
