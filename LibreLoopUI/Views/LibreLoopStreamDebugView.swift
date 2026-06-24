import SwiftUI
import Charts
import LibreLoop

/// Developer debug view: overlays the Libre 3 glucose streams so their noise can
/// be compared directly. All series are plotted against `lifeCount` (minutes
/// since sensor start) so they line up regardless of when each notification
/// arrived.
///
/// - Realtime current (char 0898177a) and Clinical word[5] (char 08981ab8) are
///   the same per-minute value by spec, so the clinical dots should sit on the
///   realtime line — except across reconnect gaps, where only clinical is
///   buffer-replayed.
/// - Embedded historical is the finalized 5-minute point carried inside each
///   realtime frame (smoother, ~17 min lag).
/// - Raw sensor channels (clinical word1-3) are the un-processed signal, shown
///   on their own axis since they're not in mg/dL.
struct LibreLoopStreamDebugView: View {
    @StateObject private var viewModel: LibreLoopStreamDebugViewModel
    @AppStorage(LibreLoopDebugSettings.continuousClinicalKey) private var continuousClinical = false

    init(viewModel: LibreLoopStreamDebugViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            Section {
                Text("Each series is plotted by lifeCount (minutes since sensor start). Realtime current and Clinical word[5] are identical by spec — clinical dots should land on the realtime line except across reconnect gaps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Continuous clinical stream", isOn: $continuousClinical)
            } footer: {
                Text("Keeps the clinical channel subscribed so the clinical/raw charts update every minute. Off by default — only needed for stream inspection, and it adds per-reconnect clinical traffic. Takes effect on the next reconnect.")
            }

            glucoseSection
            rawSection
            noiseSection
            readsSection
        }
        .navigationTitle("Glucose Streams")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    @ViewBuilder
    private var glucoseSection: some View {
        Section("Glucose (mg/dL)") {
            if viewModel.realtime.isEmpty && viewModel.embedded.isEmpty && viewModel.clinicalCurrent.isEmpty {
                Text("Waiting for stream data…").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(viewModel.realtime) { p in
                        LineMark(x: .value("lifeCount", p.lifeCount),
                                 y: .value("mg/dL", p.value),
                                 series: .value("Series", "Realtime"))
                        .foregroundStyle(by: .value("Series", "Realtime"))
                        .symbol(.circle).symbolSize(20)
                        .interpolationMethod(.monotone)
                    }
                    ForEach(viewModel.embedded) { p in
                        LineMark(x: .value("lifeCount", p.lifeCount),
                                 y: .value("mg/dL", p.value),
                                 series: .value("Series", "Embedded 5-min"))
                        .foregroundStyle(by: .value("Series", "Embedded 5-min"))
                        .symbol(.diamond).symbolSize(28)
                        .interpolationMethod(.monotone)
                    }
                    ForEach(viewModel.clinicalCurrent) { p in
                        PointMark(x: .value("lifeCount", p.lifeCount),
                                  y: .value("mg/dL", p.value))
                        .symbol(.cross).symbolSize(28)
                        .foregroundStyle(by: .value("Series", "Clinical word[5]"))
                    }
                }
                .chartForegroundStyleScale([
                    "Realtime": Color.blue,
                    "Clinical word[5]": Color.orange,
                    "Embedded 5-min": Color.green,
                ])
                .chartXScale(domain: viewModel.xDomain ?? 0...1)
                .chartXAxisLabel("lifeCount (min)")
                .frame(height: 240)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var rawSection: some View {
        Section("Raw sensor channels (clinical word1-3)") {
            if viewModel.raw1.isEmpty {
                Text("No clinical raw data yet.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(viewModel.raw1) { p in
                        LineMark(x: .value("lifeCount", p.lifeCount), y: .value("raw", p.value),
                                 series: .value("Series", "word1"))
                        .foregroundStyle(by: .value("Series", "word1"))
                    }
                    ForEach(viewModel.raw2) { p in
                        LineMark(x: .value("lifeCount", p.lifeCount), y: .value("raw", p.value),
                                 series: .value("Series", "word2"))
                        .foregroundStyle(by: .value("Series", "word2"))
                    }
                    ForEach(viewModel.raw3) { p in
                        LineMark(x: .value("lifeCount", p.lifeCount), y: .value("raw", p.value),
                                 series: .value("Series", "word3"))
                        .foregroundStyle(by: .value("Series", "word3"))
                    }
                }
                .chartForegroundStyleScale([
                    "word1": Color.purple,
                    "word2": Color.teal,
                    "word3": Color.pink,
                ])
                .chartXScale(domain: viewModel.xDomain ?? 0...1)
                .chartXAxisLabel("lifeCount (min)")
                .frame(height: 200)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var noiseSection: some View {
        Section {
            noiseRow("Realtime", viewModel.realtime, unit: "mg/dL")
            noiseRow("Clinical word[5]", viewModel.clinicalCurrent, unit: "mg/dL")
            noiseRow("Embedded 5-min", viewModel.embedded, unit: "mg/dL")
            noiseRow("Raw word1", viewModel.raw1, unit: "")
            noiseRow("Raw word2", viewModel.raw2, unit: "")
            noiseRow("Raw word3", viewModel.raw3, unit: "")
        } header: {
            Text("Noise (mean |Δ| between consecutive points)")
        } footer: {
            Text("Lower = smoother. Realtime and Clinical word[5] should match; Embedded 5-min should be lowest.")
        }
    }

    @ViewBuilder
    private var readsSection: some View {
        Section {
            if viewModel.reads.isEmpty {
                Text("No reads captured yet.").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reads.prefix(40)) { read in
                    NavigationLink {
                        LibreLoopStreamReadDetailView(read: read)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(read.channel).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(read.receivedAt, style: .time)
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(read.summary)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Raw Reads (newest first)")
        } footer: {
            Text("Each entry is one decoded packet. Tap to see when it arrived and every decoded field — including the realtime frame's historical lag, which is why the embedded 5-min value is always ~17 min behind.")
        }
    }

    private func noiseRow(_ label: String, _ points: [LibreLoopStreamDebugViewModel.Point], unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let n = LibreLoopStreamDebugViewModel.meanAbsDelta(points) {
                Text(String(format: "%.1f%@", n, unit.isEmpty ? "" : " \(unit)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            Text("(\(points.count))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
    }
}

/// Full property dump for a single captured read.
struct LibreLoopStreamReadDetailView: View {
    let read: LibreLoopStreamReadRecord

    var body: some View {
        List {
            Section {
                LabeledContent("Stream", value: read.channel)
                LabeledContent("Received", value: read.receivedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Summary", value: read.summary)
            }
            Section("Decoded fields") {
                ForEach(read.properties) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(p.value)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .navigationTitle(read.channel)
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
final class LibreLoopStreamDebugViewModel: ObservableObject {
    struct Point: Identifiable {
        let id: Int          // lifeCount is unique per series
        let lifeCount: Int
        let value: Double
    }

    @Published private(set) var realtime: [Point] = []
    @Published private(set) var clinicalCurrent: [Point] = []
    @Published private(set) var embedded: [Point] = []
    @Published private(set) var raw1: [Point] = []
    @Published private(set) var raw2: [Point] = []
    @Published private(set) var raw3: [Point] = []
    @Published private(set) var reads: [LibreLoopStreamReadRecord] = []

    private let cgmManager: LibreLoopCGMManager
    private var timer: Timer?

    init(cgmManager: LibreLoopCGMManager) {
        self.cgmManager = cgmManager
        // Cheap init (no snapshot) so it's safe to rebuild on each parent render;
        // the first refresh runs from start() on appear.
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // lifeCount 0 isn't a real reading minute; a stray 0 point would stretch
        // the x-axis back to the origin and squish the actual data.
        realtime = cgmManager.recentSamples
            .filter { $0.lifeCount > 0 }
            .map { Point(id: Int($0.lifeCount), lifeCount: Int($0.lifeCount), value: $0.valueMgDL) }
            .sorted { $0.lifeCount < $1.lifeCount }

        let clinical = cgmManager.recentClinicalStream.filter { $0.lifeCount > 0 }
        clinicalCurrent = clinical
            .compactMap { s in s.currentMgDL.map { Point(id: Int(s.lifeCount), lifeCount: Int(s.lifeCount), value: $0) } }
            .sorted { $0.lifeCount < $1.lifeCount }
        raw1 = clinical.map { Point(id: Int($0.lifeCount), lifeCount: Int($0.lifeCount), value: Double($0.rawWord1)) }
            .sorted { $0.lifeCount < $1.lifeCount }
        raw2 = clinical.map { Point(id: Int($0.lifeCount), lifeCount: Int($0.lifeCount), value: Double($0.rawWord2)) }
            .sorted { $0.lifeCount < $1.lifeCount }
        raw3 = clinical.map { Point(id: Int($0.lifeCount), lifeCount: Int($0.lifeCount), value: Double($0.rawWord3)) }
            .sorted { $0.lifeCount < $1.lifeCount }

        embedded = cgmManager.recentEmbeddedHistorical
            .filter { $0.lifeCount > 0 }
            .map { Point(id: Int($0.lifeCount), lifeCount: Int($0.lifeCount), value: $0.mgdl) }
            .sorted { $0.lifeCount < $1.lifeCount }

        reads = cgmManager.recentReads
    }

    /// Tight x-domain (shared by both charts so they line up) covering exactly
    /// the captured data, so a long-running sensor's large lifeCount values
    /// aren't squished against the right edge. Padded when only one point.
    var xDomain: ClosedRange<Int>? {
        let lifeCounts = (realtime + clinicalCurrent + embedded + raw1 + raw2 + raw3).map(\.lifeCount)
        guard let lo = lifeCounts.min(), let hi = lifeCounts.max() else { return nil }
        return lo == hi ? (lo - 1)...(hi + 1) : lo...hi
    }

    /// Mean absolute change between consecutive (lifeCount-sorted) points — a
    /// simple noise proxy. nil for fewer than two points.
    static func meanAbsDelta(_ points: [Point]) -> Double? {
        guard points.count > 1 else { return nil }
        let deltas = zip(points.dropFirst(), points).map { abs($0.value - $1.value) }
        return deltas.reduce(0, +) / Double(deltas.count)
    }
}
