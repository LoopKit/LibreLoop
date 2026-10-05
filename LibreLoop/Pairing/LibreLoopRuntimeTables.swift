import Foundation
import RoundWhiteDiscKit

/// RoundWhiteDiscKit ships without its lookup tables; they come from a blob
/// published on Arweave. It is downloaded once, kept in Application Support,
/// and installed before any pairing or authorization.
public enum LibreLoopRuntimeTables {
    static let blob = ArweaveBlob(
        name: "runtime tables",
        transactionID: "8ran9sd_2k7dvzVPPRGs3sVq5mgP74UZ4A0V-mr2ag0",
        fileName: "roundwhitedisckit-runtime-tables-v2.xz",
        isInstalled: { RoundWhiteDiscKit.runtimeTablesInstalled },
        install: RoundWhiteDiscKit.installRuntimeTables
    )

    static var isInstalled: Bool { blob.isInstalled() }

    public static func ensureInstalled() async throws {
        try await blob.ensureInstalled()
    }
}

/// The plain-key app identities used to pair without the whitebox, published
/// the same way as the runtime tables.
public enum LibreLoopAppIdentities {
    static let blob = ArweaveBlob(
        name: "app identities",
        transactionID: "9XxAxx8xSsr8uPNYPCycBjNSzVZFVpgxJsCoAo4OW1Y",
        fileName: "roundwhitedisckit-app-identities-v1.xz",
        isInstalled: { AppIdentities.isInstalled },
        install: AppIdentities.install
    )

    public static func ensureInstalled() async throws {
        try await blob.ensureInstalled()
    }
}

/// A blob on Arweave that RoundWhiteDiscKit verifies against a pinned digest.
/// Downloaded once and kept in Application Support; concurrent callers share a
/// single attempt.
final class ArweaveBlob: @unchecked Sendable {
    /// Any gateway is safe: the package rejects a blob whose digest doesn't match.
    static let gateways = ["https://arweave.net", "https://turbo-gateway.com"]

    let name: String
    let transactionID: String
    let fileName: String
    let isInstalled: () -> Bool
    private let installBlob: (Data) throws -> Void

    private let lock = NSLock()
    private var inFlight: Task<Void, Error>?

    init(name: String, transactionID: String, fileName: String,
         isInstalled: @escaping () -> Bool, install: @escaping (Data) throws -> Void) {
        self.name = name
        self.transactionID = transactionID
        self.fileName = fileName
        self.isInstalled = isInstalled
        self.installBlob = install
    }

    func ensureInstalled() async throws {
        if isInstalled() { return }
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

    private func install() async throws {
        if let saved = try? Data(contentsOf: fileURL) {
            do {
                try installBlob(saved)
                llog("\(name): installed saved blob (\(saved.count) bytes)")
                return
            } catch {
                llog("\(name): saved blob rejected (\(error)); downloading again")
            }
        }
        guard !transactionID.isEmpty else {
            llog("\(name): no Arweave transaction configured")
            throw URLError(.badURL)
        }

        var lastError: Error = URLError(.badURL)
        for gateway in Self.gateways {
            guard let url = URL(string: "\(gateway)/\(transactionID)") else { continue }
            do {
                let data = try await download(url)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                llog("\(name): installed \(data.count) bytes from \(gateway)")
                return
            } catch {
                llog("\(name): \(gateway) failed: \(error)")
                lastError = error
            }
        }
        throw lastError
    }

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        // Verifies the payload against the digest pinned in RoundWhiteDiscKit.
        try installBlob(data)
        return data
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibreLoop", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
