import Foundation
import Security
import LibreCRKit

/// Orchestrates a fresh Libre 3 sensor pairing:
///   1. CoreNFC activation (provides bleAddress + blePIN + sensor serial)
///   2. BLE scan + connect to the just-activated sensor
///   3. Cryptographic first-pair handshake (yields kEnc + ivEnc)
///
/// Hides LibreCRKit from upper layers (UI, CGMManager) so we can swap
/// implementations later without rewriting callers.
public final class LibreLoopPairingService {

    public struct Result: Sendable, Equatable {
        public let receiverID: UInt32
        public let sensorSerial: String
        public let bleAddress: String?
        public let blePIN: Data
        public let activatedAt: Date
        public let kEnc: Data
        public let ivEnc: Data
    }

    public enum Stage: Sendable, Equatable {
        case nfcScanning
        case bleSearching
        case bleConnecting
        case handshaking
    }

    public enum Failure: Error, CustomStringConvertible {
        case nfcNoActivationResponse
        case bleNoSensorDiscovered
        case entropy(OSStatus)
        case underlying(String)

        public var description: String {
            switch self {
            case .nfcNoActivationResponse:
                return "No activation response from the sensor. Try scanning again."
            case .bleNoSensorDiscovered:
                return "Couldn't find the sensor over Bluetooth. Make sure the sensor is on your arm and Bluetooth is on."
            case .entropy(let status):
                return "Couldn't generate cryptographic entropy (OSStatus \(status))."
            case .underlying(let message):
                return message
            }
        }
    }

    public init() {}

    public func pairFreshSensor(
        receiverID: UInt32 = UInt32.random(in: 1...UInt32.max),
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> Result {
        // 1. NFC activation
        onStage(.nfcScanning)
        let nfcReader = Libre3NFCActivationReader()
        let scanResult: Libre3NFCScanResult
        do {
            scanResult = try await nfcReader.scan(
                mode: .activateFreshSensor(receiverID: receiverID, timeSeconds: nil)
            )
        } catch {
            throw Failure.underlying("NFC scan failed: \(error.localizedDescription)")
        }
        guard let activation = scanResult.activationResponse else {
            throw Failure.nfcNoActivationResponse
        }

        // 2. BLE scan + connect
        onStage(.bleSearching)
        let scanner = SensorScanner(configuration: .foreground)
        try await scanner.waitUntilReady()

        var discovered: DiscoveredSensor?
        for await sensor in scanner.startScan() {
            discovered = sensor
            break
        }
        guard let sensor = discovered else {
            throw Failure.bleNoSensorDiscovered
        }

        onStage(.bleConnecting)
        let session: SensorSession
        do {
            session = try await scanner.connect(sensor.peripheral, timeout: 120)
        } catch {
            throw Failure.underlying("BLE connection failed: \(error.localizedDescription)")
        }

        // 3. Handshake
        onStage(.handshaking)
        let transport = SensorSessionTransport(session: session)
        let phoneCert = try PhoneCert.bundledFirstPair()
        let pairingFlow = PairingFlow(
            transport: transport,
            phoneCert: phoneCert,
            eventLogger: nil
        )

        let handshake: FirstPairDerivedHandshakeResult
        do {
            handshake = try await pairingFlow.runCommandGatedFirstPairHandshake(
                blePIN: activation.blePIN,
                entropySource: Self.secureRandomBytes(count:)
            )
        } catch {
            throw Failure.underlying("Pairing handshake failed: \(error.localizedDescription)")
        }

        let material = handshake.handshake.sessionMaterial
        return Result(
            receiverID: receiverID,
            sensorSerial: scanResult.patchInfo.serialNumber,
            bleAddress: activation.bleAddressDisplay,
            blePIN: activation.blePIN,
            activatedAt: Date(),
            kEnc: material.kEnc,
            ivEnc: material.ivEnc
        )
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.entropy(status) }
        return Data(buffer)
    }
}
