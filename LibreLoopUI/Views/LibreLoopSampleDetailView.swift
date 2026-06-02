import SwiftUI
import LibreLoop

/// All the diagnostic data we have on one realtime glucose sample,
/// pushed when the user taps a row in Recent Readings.
struct LibreLoopSampleDetailView: View {
    let sample: LibreLoopGlucoseSample

    var body: some View {
        List {
            Section("Reading") {
                LabeledContent("Value", value: "\(Int(sample.valueMgDL)) mg/dL")
                LabeledContent("Time", value: sample.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Time (relative)") {
                    Text(sample.date, style: .relative)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Trend", value: trendLabel)
                if let rate = sample.rateOfChangeMgDLPerMinute {
                    LabeledContent("Rate of change", value: String(format: "%+.2f mg/dL/min", rate))
                } else {
                    LabeledContent("Rate of change", value: "—")
                }
            }

            Section("Quality") {
                LabeledContent("Sent to Loop") {
                    HStack(spacing: 6) {
                        // Actionable readings flow into Loop's dosing math;
                        // non-actionable readings still go to Loop but as
                        // display-only. Show as info, not warning.
                        Image(systemName: sample.isActionable ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(sample.isActionable ? .green : .secondary)
                        Text(sample.isActionable ? "Yes" : "Display only")
                    }
                }
                if let issue = sample.qualityIssue {
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
                        Image(systemName: sample.wasForwarded ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(sample.wasForwarded ? .green : .secondary)
                        Text(sample.wasForwarded ? "Yes" : "No")
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
