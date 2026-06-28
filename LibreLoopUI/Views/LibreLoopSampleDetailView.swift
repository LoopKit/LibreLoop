import SwiftUI
import LibreLoop
import LoopAlgorithm
import LoopKitUI

/// All the diagnostic data we have on one realtime glucose sample,
/// pushed when the user taps a row in Recent Readings.
struct LibreLoopSampleDetailView: View {
    let sample: LibreLoopGlucoseSample
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.appName) private var appName

    var body: some View {
        List {
            Section(LocalizedString("Reading", comment: "Sample detail section: reading")) {
                LabeledContent(LocalizedString("Value", comment: "Sample detail: glucose value"), value: displayGlucosePreference.format(
                    LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL)))
                LabeledContent(LocalizedString("Time", comment: "Sample detail: time"), value: sample.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent(LocalizedString("Time (relative)", comment: "Sample detail: relative time")) {
                    Text(sample.date, style: .relative)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(LocalizedString("Trend", comment: "Sample detail: trend"), value: trendLabel)
                if let rate = sample.rateOfChangeMgDLPerMinute {
                    LabeledContent(LocalizedString("Rate of change", comment: "Sample detail: rate of change"), value: displayGlucosePreference.formatMinuteRate(
                        LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: rate)))
                } else {
                    LabeledContent(LocalizedString("Rate of change", comment: "Sample detail: rate of change"), value: "—")
                }
            }

            if let issue = sample.qualityIssue {
                Section(LocalizedString("Quality", comment: "Sample detail section: quality")) {
                    LabeledContent(LocalizedString("Issue", comment: "Sample detail: quality issue")) {
                        Text(issue)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(String(format: LocalizedString("Forwarding to %1$@", comment: "Sample detail section: forwarding (1: appName)"), appName)) {
                LabeledContent(LocalizedString("Sent", comment: "Sample detail: sent to Loop")) {
                    HStack(spacing: 6) {
                        Image(systemName: sentIcon)
                            .foregroundStyle(sentColor)
                        Text(sentLabel)
                    }
                }
                if let reason = sample.forwardSkipReason, !sample.wasForwarded {
                    LabeledContent(LocalizedString("Reason", comment: "Sample detail: not-forwarded reason")) {
                        Text(reason)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(LocalizedString("Source", comment: "Sample detail section: source")) {
                LabeledContent(LocalizedString("Path", comment: "Sample detail: source path"), value: sourceLabel)
                LabeledContent("LifeCount", value: "\(sample.lifeCount)")
                    .monospacedDigit()
            }

            Section(LocalizedString("Sensor diagnostics", comment: "Sample detail section: diagnostics")) {
                LabeledContent(LocalizedString("Temperature (raw)", comment: "Sample detail: raw sensor temperature"), value: "0x\(String(sample.sensorTemperatureRaw, radix: 16, uppercase: true)) (\(sample.sensorTemperatureRaw))")
                    .monospaced()
                    .font(.footnote)
            }
        }
        .navigationTitle(LocalizedString("Sample detail", comment: "Sample detail screen title"))
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
        guard sample.wasForwarded else { return LocalizedString("No", comment: "Sample detail: not sent to Loop") }
        return sample.isActionable
            ? LocalizedString("Yes", comment: "Sample detail: sent to Loop")
            : LocalizedString("Yes (display only)", comment: "Sample detail: sent display-only")
    }

    private var trendLabel: String {
        switch sample.trend {
        case .notDetermined:   return "—"
        case .risingQuickly:   return LocalizedString("Rising quickly ⇈", comment: "Trend: rising quickly")
        case .rising:          return LocalizedString("Rising ↗", comment: "Trend: rising")
        case .stable:          return LocalizedString("Stable →", comment: "Trend: stable")
        case .falling:         return LocalizedString("Falling ↘", comment: "Trend: falling")
        case .fallingQuickly:  return LocalizedString("Falling quickly ⇊", comment: "Trend: falling quickly")
        }
    }

    private var sourceLabel: String {
        switch sample.source {
        case .realtime:           return LocalizedString("Realtime (live BLE)", comment: "Sample source: realtime")
        case .historicalBackfill: return LocalizedString("Historical backfill", comment: "Sample source: historical backfill")
        case .clinicalBackfill:   return LocalizedString("Clinical backfill", comment: "Sample source: clinical backfill")
        }
    }
}
