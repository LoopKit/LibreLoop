#if targetEnvironment(simulator)
import Foundation
import RoundWhiteDiscKit

/// The iOS Simulator has no NFC and no Libre 3, so pairing there talks to
/// libre3sim (https://github.com/LoopKit/libre3sim), which reaches the app's
/// Bluetooth through ImpossiBLE. Its HTTP API stands in for the sensor's NFC
/// tag and supplies the app credential and the key that signs its sensors'
/// certificates. Set LIBRE3SIM_URL to reach it somewhere other than port 8080.
enum LibreLoopSimulator {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["LIBRE3SIM_URL"] ?? "http://127.0.0.1:8080")!
    }

    static func appCredentials() async throws -> Data {
        try await get("app-credentials")
    }

    static func patchSigningKeys() async throws -> [Data] {
        struct Key: Decodable { let publicKey: String }
        let key = try JSONDecoder().decode(Key.self, from: try await get("patch-signing-key"))
        guard let data = Data(simulatorHex: key.publicKey) else {
            throw Failure(message: "libre3sim sent a malformed patch-signing key")
        }
        return [data]
    }

    /// An ISO 15693 custom command, answered as CoreNFC would return it.
    static func nfc(code: UInt8, parameters: Data) async throws -> Data {
        struct Reply: Decodable {
            let response: String?
            let error: String?
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("nfc"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": Int(code),
            "parameters": parameters.map { String(format: "%02x", $0) }.joined(),
        ])
        let reply = try JSONDecoder().decode(Reply.self, from: try await load(request))
        guard let hex = reply.response, let data = Data(simulatorHex: hex) else {
            throw Failure(message: reply.error ?? "libre3sim gave no NFC response")
        }
        return data
    }

    private static func get(_ path: String) async throws -> Data {
        try await load(URLRequest(url: baseURL.appendingPathComponent(path)))
    }

    private static func load(_ request: URLRequest) async throws -> Data {
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            throw Failure(message: "libre3sim is not running at \(baseURL.absoluteString): \(error.localizedDescription)")
        }
    }
}

/// Libre3NFCActivationReader's scan, with libre3sim as the tag.
final class LibreLoopSimulatedNFCReader {
    func scan(mode: Libre3NFCScanMode) async throws -> Libre3NFCScanResult {
        let patchInfo = try Libre3NFCPatchInfo(raw: await LibreLoopSimulator.nfc(code: 0xa1, parameters: Data()))
        let commandCode: NFCActivationCommandCode
        let receiverID: UInt32
        let explicitTime: UInt32?
        switch mode {
        case .readPatchInfo:
            return Libre3NFCScanResult(patchInfo: patchInfo)
        case .activateFreshSensor(let id, let time):
            guard patchInfo.recommendedCommandCode == .activate else {
                throw Libre3NFCError.unexpectedSensorState(patchInfo: patchInfo)
            }
            (commandCode, receiverID, explicitTime) = (.activate, id, time)
        case .switchReceiver(let id, let time):
            guard patchInfo.recommendedCommandCode == .switchReceiver else {
                throw Libre3NFCError.unexpectedSensorState(patchInfo: patchInfo)
            }
            (commandCode, receiverID, explicitTime) = (.switchReceiver, id, time)
        case .activateOrSwitchReceiver(let id, let time):
            (commandCode, receiverID, explicitTime) = (patchInfo.recommendedCommandCode, id, time)
        case .forceActivationCommand(let code, let id, let time):
            (commandCode, receiverID, explicitTime) = (code, id, time)
        }
        let parameters = NFCActivationCommand.customRequestParameters(
            timeSeconds: explicitTime ?? UInt32(Date().timeIntervalSince1970) - 1,
            receiverID: receiverID
        )
        let raw = try await LibreLoopSimulator.nfc(code: commandCode.rawValue, parameters: parameters)
        return Libre3NFCScanResult(
            patchInfo: patchInfo,
            commandCode: commandCode,
            commandParameters: parameters,
            activationResponse: try Libre3NFCActivationResponse(raw: raw)
        )
    }
}

private extension Data {
    init?(simulatorHex hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
#endif
