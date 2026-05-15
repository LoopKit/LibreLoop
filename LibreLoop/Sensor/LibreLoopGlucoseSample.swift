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

    public let date: Date
    public let valueMgDL: Double
    public let trend: Trend
    public let rateOfChangeMgDLPerMinute: Double?
    public let lifeCount: UInt16
    public let sensorTemperatureRaw: UInt16
    public let isActionable: Bool
    /// Short human-readable reason when the sensor refuses to flag the
    /// reading actionable (e.g. "Warming up: 18 min remaining",
    /// "Sensor condition: invalid"). nil when the reading IS actionable.
    public let qualityIssue: String?

    public init(
        date: Date,
        valueMgDL: Double,
        trend: Trend,
        rateOfChangeMgDLPerMinute: Double?,
        lifeCount: UInt16,
        sensorTemperatureRaw: UInt16,
        isActionable: Bool,
        qualityIssue: String? = nil
    ) {
        self.date = date
        self.valueMgDL = valueMgDL
        self.trend = trend
        self.rateOfChangeMgDLPerMinute = rateOfChangeMgDLPerMinute
        self.lifeCount = lifeCount
        self.sensorTemperatureRaw = sensorTemperatureRaw
        self.isActionable = isActionable
        self.qualityIssue = qualityIssue
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
        return raw
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
