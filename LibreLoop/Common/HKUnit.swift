import HealthKit

// LoopKit's HKUnit extensions are internal-scoped, so each plugin redeclares
// the units it needs. Matches the pattern in G7SensorKit/Common/HKUnit.swift.
public extension HKUnit {
    static let milligramsPerDeciliter: HKUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
    static let milligramsPerDeciliterPerMinute: HKUnit = milligramsPerDeciliter.unitDivided(by: .minute())

    /// Shim for the `LoopUnit.localizedShortUnitString` API used by views
    /// written against tidepool-sync's LoopKit. Covers the glucose units the
    /// UI actually surfaces; falls back to `unitString` for anything else.
    var localizedShortUnitString: String {
        if self == .milligramsPerDeciliter {
            return NSLocalizedString("mg/dL", comment: "Short unit string for mg/dL")
        }
        if self == HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter()) {
            return NSLocalizedString("mmol/L", comment: "Short unit string for mmol/L")
        }
        return unitString
    }
}
