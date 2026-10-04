import Foundation
import RoundWhiteDiscKit

/// RoundWhiteDiscKit ships without its lookup tables; they come from a blob
/// published on Arweave. It is downloaded once, kept in Application Support,
/// and installed before any pairing or authorization.
public enum LibreLoopRuntimeTables {
    static let transactionID = "8ran9sd_2k7dvzVPPRGs3sVq5mgP74UZ4A0V-mr2ag0"

    /// Any gateway is safe: the package rejects a blob whose digest doesn't match.
    static let gateways = ["https://arweave.net", "https://turbo-gateway.com"]

    static var isInstalled: Bool {
        RoundWhiteDiscKit.runtimeTablesInstalled
    }

    private static let lock = NSLock()
    private static var inFlight: Task<Void, Error>?

    /// Installs the saved blob, downloading and saving it first if there isn't
    /// one. Concurrent callers share a single attempt.
    public static func ensureInstalled() async throws {
        if isInstalled { return }
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
                try RoundWhiteDiscKit.installRuntimeTables(saved)
                return
            } catch {
                llog("runtime tables: saved blob rejected (\(error)); downloading again")
            }
        }

        var lastError: Error = URLError(.badURL)
        for gateway in gateways {
            guard let url = URL(string: "\(gateway)/\(transactionID)") else { continue }
            do {
                let data = try await download(url)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                llog("runtime tables: installed \(data.count) bytes from \(gateway)")
                return
            } catch {
                llog("runtime tables: \(gateway) failed: \(error)")
                lastError = error
            }
        }
        throw lastError
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        // Verifies the payload against the digest pinned in RoundWhiteDiscKit.
        try RoundWhiteDiscKit.installRuntimeTables(data)
        return data
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibreLoop", isDirectory: true)
            .appendingPathComponent("roundwhitedisckit-runtime-tables-v2.xz")
    }
}
