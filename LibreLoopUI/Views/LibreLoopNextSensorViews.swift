import SwiftUI
import LibreLoop

/// The outcome of "Start next sensor early", shown as an alert.
struct LibreLoopNextSensorMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension LibreLoopSettingsViewModel {
    func startNextSensorEarly() {
        guard !isStartingNextSensor else { return }
        isStartingNextSensor = true
        Task { @MainActor in
            defer { self.isStartingNextSensor = false }
            do {
                let result = try await self.cgmManager.startNextSensorEarly()
                self.nextSensorMessage = Self.message(for: result)
            } catch {
                self.nextSensorMessage = LibreLoopNextSensorMessage(
                    title: LocalizedString("Couldn't start the sensor", comment: "Start next sensor early: failure alert title"),
                    message: String(describing: error)
                )
            }
        }
    }

    func forgetNextSensor() {
        cgmManager.forgetNextSensor()
    }

    static func message(for result: LibreLoopPairingService.PreActivationResult) -> LibreLoopNextSensorMessage {
        let notStarted = LocalizedString("Sensor not started", comment: "Start next sensor early: nothing was sent to the scanned sensor (alert title)")
        switch result {
        case .activated(let next):
            return LibreLoopNextSensorMessage(
                title: LocalizedString("Next sensor started", comment: "Start next sensor early: success alert title"),
                message: String(
                    format: LocalizedString("Sensor %1$@ is warming up and will be ready at about %2$@. Your current sensor keeps working until you switch.", comment: "Start next sensor early: success alert message (1: serial, 2: ready time)"),
                    next.serial,
                    next.readyAt.formatted(date: .omitted, time: .shortened)
                )
            )
        case .alreadyStarted:
            return LibreLoopNextSensorMessage(
                title: notStarted,
                message: LocalizedString("This sensor has already been started early. Switch to it under Next Sensor.", comment: "Start next sensor early: the scanned sensor is the next sensor already")
            )
        case .sensorInUse:
            return LibreLoopNextSensorMessage(
                title: notStarted,
                message: LocalizedString("This is the sensor in use. Scan the new sensor instead.", comment: "Start next sensor early: the scanned sensor is the current one")
            )
        case .alreadyActive:
            return LibreLoopNextSensorMessage(
                title: notStarted,
                message: LocalizedString("This sensor is already active. To use it, choose Pair new sensor.", comment: "Start next sensor early: the scanned sensor was activated before")
            )
        case .sensorEnded:
            return LibreLoopNextSensorMessage(
                title: notStarted,
                message: LocalizedString("This sensor has ended and can't be used again.", comment: "Start next sensor early: the scanned sensor has ended")
            )
        case .sensorInsertionFailed:
            return LibreLoopNextSensorMessage(
                title: notStarted,
                message: LocalizedString("This sensor wasn't inserted correctly and can't be used.", comment: "Start next sensor early: the scanned sensor failed insertion")
            )
        }
    }
}

extension LibreLoopSettingsView {
    /// The sensor started early: how far its warm-up is, and the switch.
    @ViewBuilder
    var nextSensorSection: some View {
        if let next = viewModel.nextSensor {
            Section {
                LabeledContent(LocalizedString("Serial", comment: "Sensor serial row label"), value: next.serial)
                    .monospaced()
                    .font(.footnote)
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent(LocalizedString("Status", comment: "Next sensor: warm-up status row label")) {
                        Self.nextSensorStatus(next, now: context.date)
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    LabeledContent(
                        LocalizedString("Remaining", comment: "Next sensor: remaining wear time row label"),
                        value: Self.remainingFormatter.string(from: next.remainingLife(at: context.date)) ?? ""
                    )
                }
                Button(LocalizedString("Switch to next sensor", comment: "Next sensor: switch button")) {
                    confirmingSwitchToNextSensor = true
                }
                Button(LocalizedString("Forget", comment: "Next sensor: forget button"), role: .destructive) {
                    confirmingForgetNextSensor = true
                }
            } header: {
                Text(LocalizedString("Next Sensor", comment: "Settings section: the sensor started early"))
            } footer: {
                Text(String(
                    format: LocalizedString("Started %@. Your current sensor keeps working until you switch.", comment: "Next sensor section footer (1: activation date and time)"),
                    next.activatedAt.formatted(date: .abbreviated, time: .shortened)
                ))
            }
        }
    }

    /// Shown above the Next Sensor section's replace prompt when the current
    /// sensor has ended or failed.
    @ViewBuilder
    func nextSensorReplacePrompt(_ next: LibreLoopNextSensor) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(next.isReady(at: context.date)
                 ? LocalizedString("Your next sensor is ready.", comment: "Replace prompt when a sensor started early has warmed up")
                 : String(format: LocalizedString("Your next sensor is warming up and will be ready at about %@.", comment: "Replace prompt when a sensor started early is still warming up (1: ready time)"), next.readyAt.formatted(date: .omitted, time: .shortened)))
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    var startNextSensorSection: some View {
        if viewModel.canStartNextSensorEarly {
            Section {
                Button {
                    confirmingStartNextSensor = true
                } label: {
                    HStack {
                        Text(LocalizedString("Start next sensor early", comment: "Start next sensor early button"))
                        if viewModel.isStartingNextSensor {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isStartingNextSensor)
            } footer: {
                Text(LocalizedString("Apply your next sensor, then scan it here. This starts its warm-up and its wear time now, and your current sensor keeps working. When you're ready, switch to the new sensor with one more scan.", comment: "Start next sensor early explainer"))
            }
        }
    }

    @ViewBuilder
    static func nextSensorStatus(_ next: LibreLoopNextSensor, now: Date) -> some View {
        if next.isReady(at: now) {
            Label(LocalizedString("Ready", comment: "Next sensor: warm-up finished"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Text(String(
                format: LocalizedString("Warming up · ready ≈ %@", comment: "Next sensor: still warming up (1: ready time)"),
                next.readyAt.formatted(date: .omitted, time: .shortened)
            ))
            .foregroundStyle(.secondary)
        }
    }

    static let remainingFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
}

/// The next sensor's confirmations, attached at the List level like the
/// screen's other dialogs (inside a Section they'd be dismissed when rows rebuild).
struct LibreLoopNextSensorDialogs: ViewModifier {
    @ObservedObject var viewModel: LibreLoopSettingsViewModel
    @Binding var confirmingStart: Bool
    @Binding var confirmingSwitch: Bool
    @Binding var confirmingForget: Bool
    let onSwitch: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(LocalizedString("Start the next sensor now?", comment: "Start next sensor early: confirmation title"), isPresented: $confirmingStart, titleVisibility: .visible) {
                Button(LocalizedString("Scan New Sensor", comment: "Start next sensor early: confirm and scan")) {
                    viewModel.startNextSensorEarly()
                }
                Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
            } message: {
                Text(LocalizedString("Apply the new sensor first. Scanning it starts its warm-up and its wear time now, even if you switch to it later. Your current sensor keeps working.", comment: "Start next sensor early: confirmation message"))
            }
            .confirmationDialog(LocalizedString("Switch to the next sensor?", comment: "Switch to next sensor: confirmation title"), isPresented: $confirmingSwitch, titleVisibility: .visible) {
                Button(LocalizedString("Switch", comment: "Switch to next sensor: confirm"), action: onSwitch)
                Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
            } message: {
                Text(LocalizedString("This stops monitoring the current sensor and pairs the next one. Hold your phone to the next sensor when asked.", comment: "Switch to next sensor: confirmation message"))
            }
            .confirmationDialog(LocalizedString("Forget the next sensor?", comment: "Forget next sensor: confirmation title"), isPresented: $confirmingForget, titleVisibility: .visible) {
                Button(LocalizedString("Forget", comment: "Next sensor: forget button"), role: .destructive) {
                    viewModel.forgetNextSensor()
                }
                Button(LocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
            } message: {
                Text(LocalizedString("LibreLoop stops keeping track of it. This doesn't stop the sensor: it keeps running and its wear time keeps counting. To use it later, choose Pair new sensor and scan it.", comment: "Forget next sensor: confirmation message"))
            }
            .alert(item: $viewModel.nextSensorMessage) { message in
                Alert(title: Text(message.title), message: Text(message.message))
            }
    }
}
