import SwiftUI
import LibreLoop
import LoopAlgorithm
import LoopKitUI

struct LibreLoopSettingsView: View {
    @ObservedObject var viewModel: LibreLoopSettingsViewModel
    @ObservedObject private var logger = LibreLoopFileLogger.shared
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.appName) private var appName
    let didFinish: () -> Void
    let replaceSensor: () -> Void
    let deleteCGM: () -> Void

    @State private var confirmingDelete = false
    @State private var confirmingReplace = false
    @State private var showingAllReadings = false
    @State private var showingMinuteByMinuteWarning = false
    @State private var activityFilter: ActivityFilter = .all
    @State private var showingAllActivity = false
    @State private var copyToast: String?

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case ble = "BLE"
        case clinical = "Clinical"
        case connection = "Connection"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            sensorImageHeader
            sensorSection
            lastReadingSection
            recentReadingsSection
            debugInfoSection
            forwardingSection
            developerSection
            activitySection
            deleteSection
        }
        .navigationTitle("FreeStyle Libre 3")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LocalizedString("Done", comment: "Done button"), action: didFinish)
            }
        }
        .confirmationDialog(LocalizedString("Delete CGM?", comment: "Delete CGM confirmation title"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(LocalizedString("Delete", comment: "Delete button"), role: .destructive, action: deleteCGM)
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
        } message: {
            Text(String(format: LocalizedString("This removes the FreeStyle Libre 3 CGM from %1$@. You'll need to re-pair to resume readings.", comment: "Delete CGM confirmation message (1: appName)"), appName))
        }
        .confirmationDialog(LocalizedString("Pair a new sensor?", comment: "Replace sensor confirmation title"), isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button(LocalizedString("Continue", comment: "Continue button"), action: replaceSensor)
            Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
        } message: {
            Text(LocalizedString("This stops monitoring the current sensor and starts pairing for a new one. The CGM stays configured with Loop.", comment: "Replace sensor confirmation message"))
        }
        // Sheet must be attached at the List level. When it's attached inside
        // a Section, the List rebuilds its rows on the state change and
        // dismisses the sheet immediately.
        .sheet(isPresented: $showingMinuteByMinuteWarning) {
            MinuteByMinuteWarningSheet(
                onEnable: {
                    viewModel.setMinuteByMinuteForwarding(true)
                    showingMinuteByMinuteWarning = false
                },
                onCancel: { showingMinuteByMinuteWarning = false }
            )
        }
        .onAppear { viewModel.subscribe() }
        .onDisappear { viewModel.unsubscribe() }
    }

    private var sensorImageHeader: some View {
        Section {
            HStack {
                Spacer()
                // Plugin frameworks load at runtime, so the image lookup
                // has to point at the framework bundle (not main). The
                // SwiftUI `Image(_:bundle:)` form doesn't resolve raw
                // PNGs in plugin framework bundles in practice — go
                // through UIImage explicitly.
                if let uiImage = UIImage(named: "FSL3-sensor",
                                         in: Bundle(for: LibreLoopSettingsViewModel.self),
                                         compatibleWith: nil) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 150, height: 150)
                }
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var sensorSection: some View {
        Section(LocalizedString("Sensor", comment: "Settings section: sensor")) {
            LibreLoopLifecycleBar(lifecycle: viewModel.lifecycle,
                                  statusDetail: viewModel.statusDetail)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 10, height: 10)
                    Text(LocalizedString("Bluetooth", comment: "Bluetooth connection row label"))
                    Spacer()
                    Text(connectionLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let error = viewModel.lastReconnectError, shouldShowReconnectError {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let at = viewModel.lastReconnectAttemptAt {
                                Text(String(format: LocalizedString("Last attempt %@", comment: "Reconnect error: time of last attempt"), Self.relative.localizedString(for: at, relativeTo: Date())))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            if let model = viewModel.sensorModel {
                LabeledContent(LocalizedString("Sensor", comment: "Sensor model row label"), value: model)
            }
            if let activated = viewModel.activatedAt {
                LabeledContent(LocalizedString("Activated", comment: "Sensor activation date row label"), value: activated.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    @ViewBuilder
    private var debugInfoSection: some View {
        let hasAny = viewModel.sensorSerial != nil
            || viewModel.bleAddress != nil
            || viewModel.blePINHex != nil
            || viewModel.receiverIDHex != nil
        if hasAny {
            Section(LocalizedString("Debug Info", comment: "Settings section: debug info")) {
                if let serial = viewModel.sensorSerial {
                    LabeledContent(LocalizedString("Serial", comment: "Sensor serial row label"), value: serial)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                if let ble = viewModel.bleAddress {
                    LabeledContent(LocalizedString("Bluetooth", comment: "Bluetooth address row label"), value: ble)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                if let pin = viewModel.blePINHex {
                    LabeledContent(LocalizedString("BLE PIN", comment: "BLE PIN row label"), value: pin)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                if let rid = viewModel.receiverIDHex {
                    LabeledContent(LocalizedString("Receiver ID", comment: "Receiver ID row label"), value: rid)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var lastReadingSection: some View {
        Section(LocalizedString("Last Reading", comment: "Settings section: last reading")) {
            if let sample = viewModel.latestSample {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayGlucosePreference.format(
                            LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
                            includeUnit: false))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(sample.isActionable ? .primary : .secondary)
                    Text(displayGlucosePreference.unit.localizedShortUnitString)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: trendSymbol(sample.trend))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(sample.date, style: .relative)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let rate = sample.rateOfChangeMgDLPerMinute {
                        Text(displayGlucosePreference.formatMinuteRate(
                                LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: rate)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.footnote)
                if !sample.isActionable {
                    // Informational, not a warning: the sensor sent a
                    // value that's forwarded to Loop as isDisplayOnly --
                    // shown on the chart but not used for dosing math.
                    Label(sample.qualityIssue ?? LocalizedString("Display only", comment: "Reading is display-only, not used for dosing"),
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.lifecycle == .failed {
                // Don't say "waiting" — the sensor has failed and won't report.
                Text(LocalizedString("No readings — replace the sensor.", comment: "Last reading placeholder when the sensor has failed"))
                    .foregroundStyle(.secondary)
            } else {
                Text(LocalizedString("Waiting for first reading…", comment: "Last reading placeholder before the first reading"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recentReadingsSection: some View {
        if !viewModel.recentSamples.isEmpty {
            Section(LocalizedString("Recent Readings", comment: "Settings section: recent readings")) {
                LibreLoopReadingHeaderRow()
                let visible = showingAllReadings ? viewModel.recentSamples : Array(viewModel.recentSamples.prefix(8))
                ForEach(visible.indices, id: \.self) { idx in
                    NavigationLink {
                        LibreLoopSampleDetailView(sample: visible[idx])
                    } label: {
                        LibreLoopReadingRow(sample: visible[idx])
                    }
                }
                if viewModel.recentSamples.count > 8 {
                    Button(showingAllReadings
                           ? LocalizedString("Show fewer", comment: "Collapse recent readings list")
                           : String(format: LocalizedString("Show all %d", comment: "Expand recent readings list to N"), viewModel.recentSamples.count)) {
                        showingAllReadings.toggle()
                    }
                }
            }
        }
    }

    /// Recent activity feed sourced from the in-memory ring buffer in
    /// LibreLoopFileLogger. This is the same content that lands in the
    /// rolling file at `libreloop/log.txt` and in os_log, just exposed
    /// in the UI so a user in the field can copy a slice into chat
    /// without USB or Console.app.
    @ViewBuilder
    private var activitySection: some View {
        let filtered = filteredLines
        Section(LocalizedString("Recent Activity", comment: "Settings section: recent activity log")) {
            Picker(LocalizedString("Filter", comment: "Activity log filter picker label"), selection: $activityFilter) {
                ForEach(ActivityFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)

            if filtered.isEmpty {
                Text(activityFilter == .all
                     ? LocalizedString("No activity logged yet.", comment: "Empty activity log")
                     : LocalizedString("No activity matching this filter.", comment: "Empty filtered activity log"))
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                let visible = showingAllActivity ? filtered : Array(filtered.suffix(12))
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    Text(formatLineForDisplay(line))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if filtered.count > 12 {
                    Button(showingAllActivity
                           ? LocalizedString("Show fewer", comment: "Collapse activity log")
                           : String(format: LocalizedString("Show all %d", comment: "Expand activity log to N lines"), filtered.count)) {
                        showingAllActivity.toggle()
                    }
                    .font(.footnote)
                }
                HStack {
                    Button {
                        copyActivity(filtered)
                    } label: {
                        Label(LocalizedString("Copy log", comment: "Copy activity log button"), systemImage: "doc.on.doc")
                    }
                    .font(.footnote)
                    Spacer()
                    if let toast = copyToast {
                        Text(toast)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private var filteredLines: [String] {
        switch activityFilter {
        case .all:
            return logger.recentLines
        case .ble:
            return logger.recentLines.filter { $0.contains("ble:") || $0.contains("reconnect:") }
        case .clinical:
            return logger.recentLines.filter { $0.contains("clinical ") }
        case .connection:
            // The BLE connection lifecycle: disconnects, our connect requests,
            // iOS connect/fail callbacks, plus the internal reconnect scheduling.
            return logger.recentLines.filter {
                $0.contains("ble: requesting connect")
                    || $0.contains("ble: didConnect")
                    || $0.contains("ble: didDisconnect")
                    || $0.contains("ble: didFailToConnect")
                    || $0.contains("monitor reported disconnect")
                    || $0.contains("reconnect:")
                    || $0.contains("BLE connect failed")
                    || $0.contains("BLE timeout")
            }
        }
    }

    /// Strip the `[file.swift:42]` source tag for on-screen display --
    /// the file location is just noise when scanning activity, and the
    /// timestamp + message is what's useful. The tag stays intact when
    /// you Copy log so re_abbot's tooling can still parse it.
    private func formatLineForDisplay(_ line: String) -> String {
        // Stored format: "<ISO8601 UTC> [file:line] message". Show a local
        // wall-clock time (so reconnection cadence is visible) + the message,
        // dropping the verbose [file:line] tag.
        var time = ""
        var rest = Substring(line)
        if let firstSpace = line.firstIndex(of: " ") {
            let stamp = String(line[..<firstSpace])
            if let date = Self.logISOParser.date(from: stamp) {
                time = Self.logTimeFormatter.string(from: date)
            }
            rest = line[line.index(after: firstSpace)...]
        }
        let message: String
        if let close = rest.firstIndex(of: "]") {
            message = String(rest[rest.index(after: close)...].drop(while: { $0 == " " }))
        } else {
            message = String(rest)
        }
        return time.isEmpty ? message : "\(time)  \(message)"
    }

    private func copyActivity(_ lines: [String]) {
        let joined = lines.joined(separator: "\n")
        UIPasteboard.general.string = joined
        withAnimation { copyToast = String(format: LocalizedString("Copied %d lines", comment: "Activity log copied confirmation"), lines.count) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { if copyToast != nil { copyToast = nil } }
        }
    }

    /// Developer diagnostics. The Glucose Streams view overlays the raw Libre 3
    /// data streams (realtime current, clinical word[5], embedded 5-min
    /// historical, and raw sensor channels) to compare their noise.
    private var developerSection: some View {
        Section(LocalizedString("Developer", comment: "Settings section: developer tools")) {
            NavigationLink {
                LibreLoopStreamDebugView(viewModel: viewModel.makeStreamDebugViewModel())
            } label: {
                Label(LocalizedString("Glucose Streams", comment: "Developer: glucose streams debug view"), systemImage: "waveform.path.ecg")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(LocalizedString("Pair new sensor", comment: "Pair new sensor button")) {
                confirmingReplace = true
            }
            Button(LocalizedString("Delete CGM", comment: "Delete CGM button"), role: .destructive) {
                confirmingDelete = true
            }
        }
    }

    /// Toggle for the per-minute experimental forwarding mode. Default is
    /// off (samples throttled to ~5 min) because Loop's dosing cadence was
    /// designed against 5-min CGM input. Turning it on requires the user
    /// to read the warning sheet.
    private var forwardingSection: some View {
        Section(String(format: LocalizedString("Forwarding to %1$@", comment: "Settings section: forwarding (1: appName)"), appName)) {
            Toggle(LocalizedString("Send every reading (experimental)", comment: "Experimental minute-by-minute forwarding toggle"), isOn: Binding(
                get: { viewModel.minuteByMinuteForwardingEnabled },
                set: { newValue in
                    if newValue {
                        showingMinuteByMinuteWarning = true
                    } else {
                        viewModel.setMinuteByMinuteForwarding(false)
                    }
                }
            ))
            Text(viewModel.minuteByMinuteForwardingEnabled
                 ? String(format: LocalizedString("Every realtime reading (~1/min) is sent to %1$@.", comment: "Forwarding footer: minute-by-minute on (1: appName)"), appName)
                 : String(format: LocalizedString("Only one reading every ~5 minutes is sent to %1$@, matching the cadence other CGMs use.", comment: "Forwarding footer: minute-by-minute off (1: appName)"), appName))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Only worth showing reconnect-error context when we're not currently
    /// connected -- a successful session clears the error but we keep the
    /// last value around for diagnostics; hiding it when green avoids stale
    /// noise.
    private var shouldShowReconnectError: Bool {
        switch viewModel.connectionStatus {
        case .connected, .notPaired: return false
        default: return true
        }
    }

    private var connectionColor: Color {
        switch viewModel.connectionStatus {
        case .connected:     return .green
        case .connecting:    return .yellow
        case .reconnecting:  return .yellow
        case .disconnected:  return .red
        case .notPaired:     return .gray
        }
    }

    private var connectionLabel: String {
        switch viewModel.connectionStatus {
        case .notPaired:    return LocalizedString("Not paired", comment: "Connection status: not paired")
        case .connecting:   return LocalizedString("Connecting…", comment: "Connection status: connecting")
        case .reconnecting: return LocalizedString("Reconnecting…", comment: "Connection status: reconnecting")
        case .connected:    return LocalizedString("Connected", comment: "Connection status: connected")
        case .disconnected: return LocalizedString("Disconnected", comment: "Connection status: disconnected")
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Parses the ISO8601 (UTC) prefix each log line is stamped with.
    private static let logISOParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Renders the log timestamp as a local wall-clock time for the in-app view.
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func trendSymbol(_ trend: LibreLoopGlucoseSample.Trend) -> String {
        switch trend {
        case .notDetermined:   return "minus"
        case .risingQuickly:   return "arrow.up"
        case .rising:          return "arrow.up.right"
        case .stable:          return "arrow.right"
        case .falling:         return "arrow.down.right"
        case .fallingQuickly:  return "arrow.down"
        }
    }
}

struct LibreLoopReadingHeaderRow: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    var body: some View {
        HStack {
            Text(LocalizedString("Time", comment: "Recent readings column header: time"))
                .frame(width: 72, alignment: .leading)
            Text(displayGlucosePreference.unit.localizedShortUnitString)
                .frame(width: 48, alignment: .trailing)
            Text("\(displayGlucosePreference.unit.localizedShortUnitString)/min")
                .frame(width: 56, alignment: .trailing)
            Spacer()
            Text(LocalizedString("Trend", comment: "Recent readings column header: trend"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct LibreLoopReadingRow: View {
    let sample: LibreLoopGlucoseSample
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    var body: some View {
        HStack {
            Text(sample.date, style: .time)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .leading)
            Text(displayGlucosePreference.format(
                    LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
                    includeUnit: false))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(sample.isActionable ? .primary : .secondary)
                .frame(width: 48, alignment: .trailing)
            if let rate = sample.rateOfChangeMgDLPerMinute {
                Text(displayGlucosePreference.formatMinuteRate(
                        LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: rate),
                        includeUnit: false))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            if !sample.isActionable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
            Spacer()
            Image(systemName: trendSymbol)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .opacity(sample.isActionable ? 1.0 : 0.7)
    }

    private var trendSymbol: String {
        switch sample.trend {
        case .notDetermined:   return "minus"
        case .risingQuickly:   return "arrow.up"
        case .rising:          return "arrow.up.right"
        case .stable:          return "arrow.right"
        case .falling:         return "arrow.down.right"
        case .fallingQuickly:  return "arrow.down"
        }
    }
}

struct MinuteByMinuteWarningSheet: View {
    let onEnable: () -> Void
    let onCancel: () -> Void
    @Environment(\.appName) private var appName

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(LocalizedString("Experimental setting", comment: "Minute-by-minute warning header"), systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)

                    Text(String(format: LocalizedString("%1$@'s algorithm was designed and tuned against CGMs that emit a new reading every 5 minutes. With this setting on, %1$@ receives a new reading from the FreeStyle Libre 3 every minute instead.", comment: "Minute-by-minute warning paragraph 1 (1: appName)"), appName))
                    Text(String(format: LocalizedString("This can change how %1$@ reacts to glucose movement compared to default behavior:", comment: "Minute-by-minute warning paragraph 2 (1: appName)"), appName))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: LocalizedString("• Dosing decisions may shift sooner or further than what %1$@'s review and tuning guidance assumes.", comment: "Minute-by-minute warning bullet 1 (1: appName)"), appName))
                        Text(LocalizedString("• Trend math, retrospective correction, and momentum effects were validated at the 5-minute cadence.", comment: "Minute-by-minute warning bullet 2"))
                        Text(LocalizedString("• You're accepting responsibility for monitoring outcomes more closely while this is on.", comment: "Minute-by-minute warning bullet 3"))
                    }
                    .font(.callout)
                    Text(LocalizedString("Leave this off unless you understand the implications. You can turn it off again at any time.", comment: "Minute-by-minute warning footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(LocalizedString("Send every reading", comment: "Minute-by-minute warning screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedString("Cancel", comment: "Cancel button"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedString("Enable", comment: "Enable button"), role: .destructive, action: onEnable)
                }
            }
        }
    }
}

final class LibreLoopSettingsViewModel: ObservableObject, LibreLoopStateObserver {
    private let cgmManager: LibreLoopCGMManager

    @Published private(set) var lifecycle: LibreLoopSensorLifecycle
    @Published private(set) var connectionStatus: LibreLoopCGMManager.ConnectionStatus
    @Published private(set) var statusDetail: String?
    @Published private(set) var lastReconnectError: String?
    @Published private(set) var lastReconnectAttemptAt: Date?
    @Published private(set) var latestSample: LibreLoopGlucoseSample?
    @Published private(set) var recentSamples: [LibreLoopGlucoseSample]
    @Published private(set) var sensorSerial: String?
    @Published private(set) var bleAddress: String?
    @Published private(set) var blePINHex: String?
    @Published private(set) var receiverIDHex: String?
    @Published private(set) var activatedAt: Date?
    @Published private(set) var sensorModel: String?
    @Published private(set) var minuteByMinuteForwardingEnabled: Bool

    init(cgmManager: LibreLoopCGMManager) {
        self.cgmManager = cgmManager
        self.lifecycle = cgmManager.sensorLifecycle
        self.connectionStatus = cgmManager.connectionStatus
        self.statusDetail = cgmManager.statusDetail
        self.lastReconnectError = cgmManager.lastReconnectError
        self.lastReconnectAttemptAt = cgmManager.lastReconnectAttemptAt
        self.latestSample = cgmManager.latestSample
        self.recentSamples = cgmManager.recentSamples
        self.sensorSerial = cgmManager.state.sensorSerial
        self.bleAddress = cgmManager.state.bleAddress
        self.blePINHex = cgmManager.state.blePIN.map(Self.hex)
        self.receiverIDHex = cgmManager.state.receiverID.map(Self.hex)
        self.activatedAt = cgmManager.state.activatedAt
        self.sensorModel = cgmManager.state.sensorModel
        self.minuteByMinuteForwardingEnabled = cgmManager.state.experimentalMinuteByMinuteForwarding
    }

    func setMinuteByMinuteForwarding(_ enabled: Bool) {
        cgmManager.setExperimentalMinuteByMinuteForwarding(enabled)
    }

    @MainActor
    func makeStreamDebugViewModel() -> LibreLoopStreamDebugViewModel {
        LibreLoopStreamDebugViewModel(cgmManager: cgmManager)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func subscribe() {
        cgmManager.addStateObserver(self)
        // Sync immediately from current state. Without this, any changes
        // that happened while we weren't observing (e.g. a Pair-new-sensor
        // flow run from a pushed view) leave the @Published fields stale.
        libreLoopCGMManager(cgmManager,
                            didUpdate: cgmManager.state,
                            latestSample: cgmManager.latestSample)
    }

    func unsubscribe() {
        cgmManager.removeStateObserver(self)
    }

    func libreLoopCGMManager(_ manager: LibreLoopCGMManager,
                              didUpdate state: LibreLoopCGMManagerState,
                              latestSample: LibreLoopGlucoseSample?) {
        DispatchQueue.main.async {
            self.lifecycle = manager.sensorLifecycle
            self.connectionStatus = manager.connectionStatus
            self.statusDetail = manager.statusDetail
            self.lastReconnectError = manager.lastReconnectError
            self.lastReconnectAttemptAt = manager.lastReconnectAttemptAt
            self.latestSample = latestSample
            self.recentSamples = manager.recentSamples
            self.sensorSerial = state.sensorSerial
            self.bleAddress = state.bleAddress
            self.blePINHex = state.blePIN.map(Self.hex)
            self.receiverIDHex = state.receiverID.map(Self.hex)
            self.activatedAt = state.activatedAt
            self.sensorModel = state.sensorModel
            self.minuteByMinuteForwardingEnabled = state.experimentalMinuteByMinuteForwarding
        }
    }
}
