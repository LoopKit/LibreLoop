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
    case expired
    case signalLost(since: Date)

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
        now: Date = Date()
    ) -> LibreLoopSensorLifecycle {
        guard sensorPaired else { return .noSensor }
        guard let activatedAt else { return .initializing }
        let age = now.timeIntervalSince(activatedAt)

        let sensorWearDuration: TimeInterval = wearDurationMinutes
            .map { TimeInterval($0) * 60 }
            ?? activeDuration

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
        case .noSensor:       return "No sensor"
        case .initializing:   return "Initializing"
        case .warmup:         return "Warming up"
        // Distinct from .warmup: initial wall-clock warmup is complete but
        // the sensor is still flagging readings as not-actionable. "Warming
        // up" here is confusing past the 60-min mark.
        case .pairingWarmup:  return "Stabilizing"
        case .active:         return "Active"
        case .expired:        return "Expired"
        case .signalLost:     return "Signal loss"
        }
    }
}
