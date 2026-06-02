import SwiftUI
import LibreLoop

struct LibreLoopSettingsView: View {
    @ObservedObject var viewModel: LibreLoopSettingsViewModel
    let didFinish: () -> Void
    let replaceSensor: () -> Void
    let deleteCGM: () -> Void

    @State private var confirmingDelete = false
    @State private var confirmingReplace = false
    @State private var showingAllReadings = false
    @State private var showingMinuteByMinuteWarning = false

    var body: some View {
        List {
            sensorImageHeader
            sensorSection
            lastReadingSection
            recentReadingsSection
            debugInfoSection
            forwardingSection
            deleteSection
        }
        .navigationTitle("FreeStyle Libre 3")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: didFinish)
            }
        }
        .confirmationDialog("Delete CGM?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteCGM)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the FreeStyle Libre 3 CGM from Loop. You'll need to re-pair to resume readings.")
        }
        .confirmationDialog("Pair a new sensor?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Continue", action: replaceSensor)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops monitoring the current sensor and starts pairing for a new one. The CGM stays configured with Loop.")
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
        Section("Sensor") {
            LibreLoopLifecycleBar(lifecycle: viewModel.lifecycle,
                                  statusDetail: viewModel.statusDetail)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 10, height: 10)
                    Text("Bluetooth")
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
                                Text("Last attempt \(Self.relative.localizedString(for: at, relativeTo: Date()))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            if let model = viewModel.sensorModel {
                LabeledContent("Sensor", value: model)
            }
            if let activated = viewModel.activatedAt {
                LabeledContent("Activated", value: activated.formatted(date: .abbreviated, time: .shortened))
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
            Section("Debug Info") {
                if let serial = viewModel.sensorSerial {
                    LabeledContent("Serial", value: serial)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                if let ble = viewModel.bleAddress {
                    LabeledContent("Bluetooth", value: ble)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                if let pin = viewModel.blePINHex {
                    LabeledContent("BLE PIN", value: pin)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                if let rid = viewModel.receiverIDHex {
                    LabeledContent("Receiver ID", value: rid)
                        .monospaced()
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var lastReadingSection: some View {
        Section("Last Reading") {
            if let sample = viewModel.latestSample {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(sample.valueMgDL))")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(sample.isActionable ? .primary : .secondary)
                    Text("mg/dL")
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
                        Text(String(format: "%+.1f mg/dL/min", rate))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.footnote)
                if !sample.isActionable {
                    // Informational, not a warning: the sensor sent a
                    // value that's forwarded to Loop as isDisplayOnly --
                    // shown on the chart but not used for dosing math.
                    Label(sample.qualityIssue ?? "Display only",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Waiting for first reading…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recentReadingsSection: some View {
        if !viewModel.recentSamples.isEmpty {
            Section("Recent Readings") {
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
                    Button(showingAllReadings ? "Show fewer" : "Show all \(viewModel.recentSamples.count)") {
                        showingAllReadings.toggle()
                    }
                }
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Pair new sensor") {
                confirmingReplace = true
            }
            Button("Delete CGM", role: .destructive) {
                confirmingDelete = true
            }
        }
    }

    /// Toggle for the per-minute experimental forwarding mode. Default is
    /// off (samples throttled to ~5 min) because Loop's dosing cadence was
    /// designed against 5-min CGM input. Turning it on requires the user
    /// to read the warning sheet.
    private var forwardingSection: some View {
        Section("Forwarding to Loop") {
            Toggle("Send every reading (experimental)", isOn: Binding(
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
                 ? "Every realtime reading (~1/min) is sent to Loop."
                 : "Only one reading every ~5 minutes is sent to Loop, matching the cadence other CGMs use.")
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
        case .notPaired:    return "Not paired"
        case .connecting:   return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .connected:    return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
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
    var body: some View {
        HStack {
            Text("Time")
                .frame(width: 72, alignment: .leading)
            Text("mg/dL")
                .frame(width: 48, alignment: .trailing)
            Text("mg/dL/min")
                .frame(width: 56, alignment: .trailing)
            Spacer()
            Text("Trend")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct LibreLoopReadingRow: View {
    let sample: LibreLoopGlucoseSample

    var body: some View {
        HStack {
            Text(sample.date, style: .time)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .leading)
            Text("\(Int(sample.valueMgDL))")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(sample.isActionable ? .primary : .secondary)
                .frame(width: 48, alignment: .trailing)
            if let rate = sample.rateOfChangeMgDLPerMinute {
                Text(String(format: "%+.1f", rate))
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Experimental setting", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)

                    Text("Loop's algorithm was designed and tuned against CGMs that emit a new reading every 5 minutes. With this setting on, Loop receives a new reading from the FreeStyle Libre 3 every minute instead.")
                    Text("This can change how Loop reacts to glucose movement compared to default behavior:")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Dosing decisions may shift sooner or further than what Loop's review and tuning guidance assumes.")
                        Text("• Trend math, retrospective correction, and momentum effects were validated at the 5-minute cadence.")
                        Text("• You're accepting responsibility for monitoring outcomes more closely while this is on.")
                    }
                    .font(.callout)
                    Text("Leave this off unless you understand the implications. You can turn it off again at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Send every reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enable", role: .destructive, action: onEnable)
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
