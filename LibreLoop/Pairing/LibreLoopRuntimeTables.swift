import CryptoKit
import Foundation
import RoundWhiteDiscKit

/// The app credentials RoundWhiteDiscKit pairs with, published on Arweave as an
/// xz-compressed JSON file. Downloaded once, kept in Application Support, and
/// installed before any pairing or authorization. Concurrent callers share a
/// single attempt.
public enum LibreLoopAppIdentities {
    static let transactionID = "qWbA3dXIHU2sU51oYtdYlouSfkCx-GczN2swLQb0upk"
    static let expectedPayloadSHA256 = "ab18ce8bcb978526e102cc5e16440f06d2aee19426c26a15dd0013d66e9995ed"
    /// Any gateway is safe: a payload whose digest doesn't match is rejected.
    static let gateways = ["https://arweave.net", "https://turbo-gateway.com"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight: Task<Void, Error>?

    public static func ensureInstalled() async throws {
        if AppIdentities.isInstalled { return }
        let task: Task<Void, Error> = lock.withLock {
            if let inFlight { return inFlight }
            let task = Task {
                defer { lock.withLock { inFlight = nil } }
                try await install()
            }
            inFlight = task
            return task
        }
        try await task.value
    }

    private static func install() async throws {
        if let saved = try? Data(contentsOf: fileURL) {
            do {
                try installBlob(saved)
                llog("app credentials: installed saved file (\(saved.count) bytes)")
                return
            } catch {
                llog("app credentials: saved file rejected (\(error)); downloading again")
            }
        }

        var lastError: Error = URLError(.badURL)
        for gateway in gateways {
            guard let url = URL(string: "\(gateway)/\(transactionID)") else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                try installBlob(data)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                llog("app credentials: installed \(data.count) bytes from \(gateway)")
                return
            } catch {
                llog("app credentials: \(gateway) failed: \(error)")
                lastError = error
            }
        }
        throw lastError
    }

    private static func installBlob(_ blob: Data) throws {
        let payload = try (blob as NSData).decompressed(using: .lzma) as Data
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedPayloadSHA256 else { throw DigestMismatch(actual: digest) }
        try AppIdentities.install(json: payload)
    }

    struct DigestMismatch: Error {
        let actual: String
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibreLoop", isDirectory: true)
            .appendingPathComponent("app-credentials-v1.xz")
    }
}
