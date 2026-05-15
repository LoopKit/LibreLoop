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
        case succeeded(serial: String)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private let cgmManager: LibreLoopCGMManager
    private let service = LibreLoopPairingService()
    private let mode: LibreLoopPairingService.Mode
    private var pairingTask: Task<Void, Never>?

    init(cgmManager: LibreLoopCGMManager, mode: LibreLoopPairingService.Mode = .fresh) {
        self.cgmManager = cgmManager
        self.mode = mode
    }

    func start() {
        guard pairingTask == nil else { return }
        pairingTask = Task { @MainActor in
            await run()
            pairingTask = nil
        }
    }

    func cancel() {
        pairingTask?.cancel()
        pairingTask = nil
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
            state = .succeeded(serial: outcome.result.sensorSerial)
        } catch {
            state = .failed(message: (error as? CustomStringConvertible)?.description
                              ?? error.localizedDescription)
        }
    }

    var statusText: String {
        switch state {
        case .idle: return "Preparing…"
        case .nfcScanning: return "Hold your phone to the sensor"
        case .bleSearching: return "Searching for sensor over Bluetooth…"
        case .bleConnecting: return "Connecting…"
        case .handshaking: return "Authenticating with sensor…"
        case .succeeded(let serial): return "Sensor \(serial) paired"
        case .failed(let message): return message
        }
    }

    var isInProgress: Bool {
        switch state {
        case .idle, .nfcScanning, .bleSearching, .bleConnecting, .handshaking:
            return true
        case .succeeded, .failed:
            return false
        }
    }

    var didSucceed: Bool {
        if case .succeeded = state { return true } else { return false }
    }

    var didFail: Bool {
        if case .failed = state { return true } else { return false }
    }
}
