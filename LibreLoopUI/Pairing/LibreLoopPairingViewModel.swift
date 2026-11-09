import Foundation
import SwiftUI
import LibreLoop

@MainActor
final class LibreLoopPairingViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case nfcScanning
        case bleSearching
        case bleConnecting
        case handshaking
        /// Switching to the next sensor, but another sensor was scanned.
        case confirmingSensor(scanned: String, expected: String)
        case succeeded(serial: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private let cgmManager: LibreLoopCGMManager
    private let service = LibreLoopPairingService()
    private let mode: LibreLoopPairingService.Mode
    private var pairingTask: Task<Void, Never>?
    /// The next sensor's serial when this pairing switches to it.
    private let expectedSerial: String?
    private var sensorConfirmation: CheckedContinuation<Bool, Never>?

    init(cgmManager: LibreLoopCGMManager, mode: LibreLoopPairingService.Mode = .fresh, expectedSerial: String? = nil) {
        self.cgmManager = cgmManager
        self.mode = mode
        self.expectedSerial = expectedSerial
    }

    func start() {
        guard pairingTask == nil else { return }
        pairingTask = Task { @MainActor in
            await run()
            pairingTask = nil
        }
    }

    func cancel() {
        resolveSensorConfirmation(continuePairing: false)
        pairingTask?.cancel()
        pairingTask = nil
    }

    /// The answer to `.confirmingSensor`: pair the scanned sensor, or stop.
    func resolveSensorConfirmation(continuePairing: Bool) {
        guard let continuation = sensorConfirmation else { return }
        sensorConfirmation = nil
        // A declined sensor's NFC response is never handed to onNFCResponse,
        // so it never reaches the manager's state.
        if continuePairing { state = .bleSearching }
        continuation.resume(returning: continuePairing)
    }

    private func confirmSensor(_ response: LibreLoopPairingService.NFCResponse) async -> Bool {
        guard let expected = expectedSerial, response.sensorSerial != expected else { return true }
        state = .confirmingSensor(scanned: response.sensorSerial, expected: expected)
        return await withCheckedContinuation { continuation in
            sensorConfirmation = continuation
        }
    }

    private func run() async {
        do {
            let outcome = try await service.pair(
                mode: mode,
                scanner: cgmManager.scanner,
                onNFCResponse: { [cgmManager] response in
                    Task { @MainActor in
                        cgmManager.applyNFCResponse(response)
                    }
                },
                continueAfterNFC: { [weak self] response in
                    await self?.confirmSensor(response) ?? false
                },
                onStage: { stage in
                    Task { @MainActor in
                        switch stage {
                        case .nfcScanning: self.state = .nfcScanning
                        case .bleSearching: self.state = .bleSearching
                        case .bleConnecting: self.state = .bleConnecting
                        case .handshaking: self.state = .handshaking
                        }
                    }
                }
            )
            try cgmManager.applyPairingOutcome(outcome)
            if expectedSerial != nil {
                // Switched, to the next sensor or, confirmed, to another one.
                cgmManager.clearNextSensorAfterAdopting(serial: outcome.result.sensorSerial, switching: true)
            }
            state = .succeeded(serial: outcome.result.sensorSerial)
        } catch is CancellationError {
            // Stopped at the sensor confirmation; the coordinator leaves.
        } catch {
            state = .failed(message: String(describing: error))
        }
    }

    var statusText: String {
        switch state {
        case .idle: return LocalizedString("Preparing…", comment: "Pairing status: preparing")
        case .nfcScanning: return LocalizedString("Hold your phone to the sensor", comment: "Pairing status: NFC scanning")
        case .bleSearching: return LocalizedString("Searching for sensor over Bluetooth…", comment: "Pairing status: BLE searching")
        case .bleConnecting: return LocalizedString("Connecting…", comment: "Pairing status: connecting")
        case .handshaking: return LocalizedString("Authenticating with sensor…", comment: "Pairing status: handshaking")
        case .confirmingSensor(let scanned, let expected):
            return String(format: LocalizedString("This is sensor %1$@, not the next sensor you started early (%2$@). Pair this sensor instead? LibreLoop then forgets the sensor you started early.", comment: "Pairing: the scanned sensor isn't the next sensor (1: scanned serial, 2: next sensor's serial)"), scanned, expected)
        case .succeeded(let serial): return String(format: LocalizedString("Sensor %@ paired", comment: "Pairing status: success with serial"), serial)
        case .failed(let message): return message
        }
    }

    var isInProgress: Bool {
        switch state {
        case .idle, .nfcScanning, .bleSearching, .bleConnecting, .handshaking:
            return true
        case .confirmingSensor, .succeeded, .failed:
            return false
        }
    }

    var didSucceed: Bool {
        if case .succeeded = state { return true } else { return false }
    }

    var isConfirmingSensor: Bool {
        if case .confirmingSensor = state { return true } else { return false }
    }

    var didFail: Bool {
        if case .failed = state { return true } else { return false }
    }
}
