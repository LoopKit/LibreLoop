import Foundation

/// A glucose reading produced by the LibreLoop CGM. Wraps LibreCRKit's
/// realtime reading so callers (UI, the manager itself, tests) don't need
/// to import LibreCRKit.
public struct LibreLoopGlucoseSample: Equatable, Sendable {
    public enum Trend: Equatable, Sendable {
        case notDetermined
        case fallingQuickly
        case falling
        case stable
        case rising
        case risingQuickly
    }

    /// Range-censoring marker. The Libre 3 caps display at 39 (low) and
    /// 501 (high); when the sensor reports a raw value outside the
    /// displayable range, `valueMgDL` is the cap and `condition` records
    /// which direction the true value lies in. Maps 1:1 to Loop's
    /// `GlucoseCondition` for forwarding.
    public enum Condition: Equatable, Sendable {
        case belowRange
        case aboveRange
    }

    public enum Source: Equatable, Sendable {
        /// Live BLE notification from the sensor (the normal path).
        case realtime
        /// Pulled from the sensor's historical-page memory after a
        /// reconnect, covering the gap window.
        case historicalBackfill
        /// Single-timepoint clinical-record backfill (fine-grained
        /// minute-resolution recovery for missed realtime ticks).
        case clinicalBackfill
    }

    public let date: Date
    public let valueMgDL: Double
    public let trend: Trend
    public let rateOfChangeMgDLPerMinute: Double?
    public let lifeCount: UInt16
    public let sensorTemperatureRaw: UInt16
    public let isActionable: Bool
    /// True when the sensor is reporting a hardware/data fault that
    /// makes this value untrustworthy at the source -- DQ errors
    /// (sensorTooHot, sensorTooCold, notDisplayable, raw) or a
    /// non-OK sensor condition. Distinct from `!isActionable`,
    /// which the sensor sets for *any* reason it doesn't want a
    /// reading vetted (including the post-warmup stabilization
    /// window where the value itself is fine). The forward path
    /// drops samples with `hasBlockingIssue == true` rather than
    /// sending them to Loop as display-only -- showing a value
    /// the sensor itself called bad would be misleading.
    public let hasBlockingIssue: Bool
    /// Range-censoring marker -- nil when `valueMgDL` is a normal in-range
    /// reading, `.belowRange` when the sensor pegged display at the low
    /// cap (39 mg/dL), `.aboveRange` at the high cap (501 mg/dL).
    public let condition: Condition?
    /// Short human-readable reason when the sensor refuses to flag the
    /// reading actionable (e.g. "Warming up: 18 min remaining",
    /// "Sensor condition: invalid"). nil when the reading IS actionable.
    public let qualityIssue: String?
    /// How this sample reached LibreLoop. Currently `recentSamples` only
    /// contains `.realtime` entries; the field exists so backfill samples
    /// can be surfaced in the same list later without a schema bump.
    public let source: Source
    /// True iff this sample was actually handed off to Loop's CGMManager
    /// delegate. Updated in place after the throttle/actionability gate
    /// runs in `ingest(_:)`.
    public let wasForwarded: Bool
    /// Short reason the sample was NOT forwarded, when `wasForwarded` is
    /// false (e.g. "Throttled (4.5 min)", "Not actionable: warming up").
    /// nil when forwarded or before the gate has run.
    public let forwardSkipReason: String?

    public init(
        date: Date,
        valueMgDL: Double,
        trend: Trend,
        rateOfChangeMgDLPerMinute: Double?,
        lifeCount: UInt16,
        sensorTemperatureRaw: UInt16,
        isActionable: Bool,
        hasBlockingIssue: Bool = false,
        condition: Condition? = nil,
        qualityIssue: String? = nil,
        source: Source = .realtime,
        wasForwarded: Bool = false,
        forwardSkipReason: String? = nil
    ) {
        self.date = date
        self.valueMgDL = valueMgDL
        self.trend = trend
        self.rateOfChangeMgDLPerMinute = rateOfChangeMgDLPerMinute
        self.lifeCount = lifeCount
        self.sensorTemperatureRaw = sensorTemperatureRaw
        self.isActionable = isActionable
        self.hasBlockingIssue = hasBlockingIssue
        self.condition = condition
        self.qualityIssue = qualityIssue
        self.source = source
        self.wasForwarded = wasForwarded
        self.forwardSkipReason = forwardSkipReason
    }

    /// Return a copy with the forwarding outcome filled in. Called from
    /// `ingest(_:)` after the throttle/actionability gate decides.
    public func withForwardingOutcome(
        wasForwarded: Bool,
        skipReason: String?
    ) -> LibreLoopGlucoseSample {
        LibreLoopGlucoseSample(
            date: date,
            valueMgDL: valueMgDL,
            trend: trend,
            rateOfChangeMgDLPerMinute: rateOfChangeMgDLPerMinute,
            lifeCount: lifeCount,
            sensorTemperatureRaw: sensorTemperatureRaw,
            isActionable: isActionable,
            hasBlockingIssue: hasBlockingIssue,
            condition: condition,
            qualityIssue: qualityIssue,
            source: source,
            wasForwarded: wasForwarded,
            forwardSkipReason: skipReason
        )
    }
}

// MARK: - Compact dictionary serialization
//
// rawState is plist-backed by Loop; we encode samples as plain Dicts of
// AnyObject-compatible types so they round-trip without needing a Codable
// JSON blob. Keys kept short to keep rawState small.

extension LibreLoopGlucoseSample {
    init?(rawValue: [String: Any]) {
        guard let date = rawValue["d"] as? Date,
              let valueMgDL = rawValue["v"] as? Double,
              let lifeCount = (rawValue["lc"] as? Int).map({ UInt16(clamping: $0) }),
              let temp = (rawValue["t"] as? Int).map({ UInt16(clamping: $0) }),
              let isActionable = rawValue["a"] as? Bool,
              let trendRaw = rawValue["tr"] as? String,
              let trend = Trend(rawString: trendRaw)
        else { return nil }
        self.date = date
        self.valueMgDL = valueMgDL
        self.trend = trend
        self.rateOfChangeMgDLPerMinute = rawValue["r"] as? Double
        self.lifeCount = lifeCount
        self.sensorTemperatureRaw = temp
        self.isActionable = isActionable
        self.qualityIssue = rawValue["q"] as? String
        self.source = (rawValue["s"] as? String).flatMap(Source.init(rawString:)) ?? .realtime
        self.wasForwarded = rawValue["fw"] as? Bool ?? false
        self.forwardSkipReason = rawValue["fr"] as? String
        self.condition = (rawValue["c"] as? String).flatMap(Condition.init(rawString:))
        self.hasBlockingIssue = rawValue["bi"] as? Bool ?? false
    }

    var rawValue: [String: Any] {
        var raw: [String: Any] = [
            "d": date,
            "v": valueMgDL,
            "lc": Int(lifeCount),
            "t": Int(sensorTemperatureRaw),
            "a": isActionable,
            "tr": trend.rawString,
        ]
        raw["r"] = rateOfChangeMgDLPerMinute
        raw["q"] = qualityIssue
        if source != .realtime { raw["s"] = source.rawString }
        if wasForwarded { raw["fw"] = true }
        raw["fr"] = forwardSkipReason
        raw["c"] = condition?.rawString
        if hasBlockingIssue { raw["bi"] = true }
        return raw
    }
}

extension LibreLoopGlucoseSample.Condition {
    var rawString: String {
        switch self {
        case .belowRange: return "lo"
        case .aboveRange: return "hi"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "lo": self = .belowRange
        case "hi": self = .aboveRange
        default:   return nil
        }
    }
}

extension LibreLoopGlucoseSample.Source {
    var rawString: String {
        switch self {
        case .realtime:           return "rt"
        case .historicalBackfill: return "hb"
        case .clinicalBackfill:   return "cb"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "rt": self = .realtime
        case "hb": self = .historicalBackfill
        case "cb": self = .clinicalBackfill
        default:   return nil
        }
    }
}

extension LibreLoopGlucoseSample.Trend {
    var rawString: String {
        switch self {
        case .notDetermined:  return "u"
        case .fallingQuickly: return "ff"
        case .falling:        return "f"
        case .stable:         return "s"
        case .rising:         return "r"
        case .risingQuickly:  return "rr"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "u":  self = .notDetermined
        case "ff": self = .fallingQuickly
        case "f":  self = .falling
        case "s":  self = .stable
        case "r":  self = .rising
        case "rr": self = .risingQuickly
        default:   return nil
        }
    }
}
