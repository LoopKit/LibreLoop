import SwiftUI
import LibreLoop
import LoopAlgorithm
import LoopKitUI

/// All the diagnostic data we have on one realtime glucose sample,
/// pushed when the user taps a row in Recent Readings.
struct LibreLoopSampleDetailView: View {
    let sample: LibreLoopGlucoseSample
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    var body: some View {
        List {
            Section("Reading") {
                LabeledContent("Value", value: displayGlucosePreference.format(
                    LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL)))
                LabeledContent("Time", value: sample.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Time (relative)") {
                    Text(sample.date, style: .relative)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Trend", value: trendLabel)
                if let rate = sample.rateOfChangeMgDLPerMinute {
                    LabeledContent("Rate of change", value: displayGlucosePreference.formatMinuteRate(
                        LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: rate)))
                } else {
                    LabeledContent("Rate of change", value: "—")
                }
            }

            if let issue = sample.qualityIssue {
                Section("Quality") {
                    LabeledContent("Issue") {
                        Text(issue)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Forwarding to Loop") {
                LabeledContent("Sent") {
                    HStack(spacing: 6) {
                        Image(systemName: sentIcon)
                            .foregroundStyle(sentColor)
                        Text(sentLabel)
                    }
                }
                if let reason = sample.forwardSkipReason, !sample.wasForwarded {
                    LabeledContent("Reason") {
                        Text(reason)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Source") {
                LabeledContent("Path", value: sourceLabel)
                LabeledContent("LifeCount", value: "\(sample.lifeCount)")
                    .monospacedDigit()
            }

            Section("Sensor diagnostics") {
                LabeledContent("Temperature (raw)", value: "0x\(String(sample.sensorTemperatureRaw, radix: 16, uppercase: true)) (\(sample.sensorTemperatureRaw))")
                    .monospaced()
                    .font(.footnote)
            }
        }
        .navigationTitle("Sample detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Three states for the Forwarding row: actionable forward (used for
    // dosing), display-only forward (chart only), and not forwarded
    // (with reason populated separately).
    private var sentIcon: String {
        guard sample.wasForwarded else { return "minus.circle" }
        return sample.isActionable ? "checkmark.circle.fill" : "info.circle"
    }

    private var sentColor: Color {
        guard sample.wasForwarded else { return .secondary }
        return sample.isActionable ? .green : .secondary
    }

    private var sentLabel: String {
        guard sample.wasForwarded else { return "No" }
        return sample.isActionable ? "Yes" : "Yes (display only)"
    }

    private var trendLabel: String {
        switch sample.trend {
        case .notDetermined:   return "—"
        case .risingQuickly:   return "Rising quickly ⇈"
        case .rising:          return "Rising ↗"
        case .stable:          return "Stable →"
        case .falling:         return "Falling ↘"
        case .fallingQuickly:  return "Falling quickly ⇊"
        }
    }

    private var sourceLabel: String {
        switch sample.source {
        case .realtime:           return "Realtime (live BLE)"
        case .historicalBackfill: return "Historical backfill"
        case .clinicalBackfill:   return "Clinical backfill"
        }
    }
}
