import SwiftUI
import LibreLoop

struct LibreLoopLifecycleBar: View {
    let lifecycle: LibreLoopSensorLifecycle
    /// Optional protocol-level detail (Authenticating / Refreshing
    /// notifications / Waiting for first reading). Surfaced as the
    /// lifecycle bar's secondary line during the Initializing phase.
    var statusDetail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lifecycle.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stateColor)
                Spacer()
                Text(secondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(stateColor)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 8)
        }
    }

    private var progress: Double {
        switch lifecycle {
        case .noSensor, .initializing, .pairingWarmup: return 0
        case .warmup(let p, _): return p
        case .active(let remaining, let total):
            return (total - remaining) / total
        case .expired: return 1
        case .signalLost: return 0
        }
    }

    private var stateColor: Color {
        switch lifecycle {
        case .noSensor:       return .gray
        case .initializing:   return .yellow
        case .warmup:         return .orange
        case .pairingWarmup:  return .orange
        case .active:         return .green
        case .expired:        return .red
        case .signalLost:     return .yellow
        }
    }

    private var secondaryText: String {
        switch lifecycle {
        case .noSensor:
            return ""
        case .initializing:
            return statusDetail ?? "Waiting for first reading"
        case .warmup(_, let remaining):
            return "\(formatRemaining(remaining)) until ready"
        case .pairingWarmup:
            // Brief window between BLE pair complete and the first
            // realtime frame arriving (~minute or less). Any reading
            // ends this state -- the actionability flag is surfaced
            // per-sample via isDisplayOnly, not held against the
            // lifecycle.
            return "Awaiting first reading"
        case .active(let remaining, _):
            return "\(formatRemaining(remaining)) remaining"
        case .expired:
            return "Replace sensor"
        case .signalLost(let since):
            return "Last reading \(Self.relativeFormatter.localizedString(for: since, relativeTo: Date()))"
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3_600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3_600)) / 60)
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        if minutes >= 1 { return "\(minutes)m" }
        return "\(Int(seconds))s"
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        let hours = Int((seconds.truncatingRemainder(dividingBy: 86_400)) / 3_600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3_600)) / 60)
        if days >= 1 { return "\(days)d \(hours)h" }
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
