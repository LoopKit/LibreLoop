import Foundation
import Combine
import os.log

/// Plain-text rolling log file written into the host app's Documents
/// directory at `libreloop/log.txt`. Mirrors every line we send through
/// `llog(...)` so a remote agent can pull the file via
/// `xcrun devicectl device copy from` without round-tripping through
/// Console.app. Bytes are capped per file and a single `.1` rotation
/// keeps roughly twice the cap on disk.
///
/// Also keeps an in-memory ring buffer (`recentLines`) so the CGM
/// Manager UI can show recent activity without anyone having to read
/// the file or stream syslog -- useful in the field when USB isn't
/// available.
///
/// All writes are serialized on a dedicated queue so callers can fire
/// from any thread.
public final class LibreLoopFileLogger: ObservableObject, @unchecked Sendable {
    public static let shared = LibreLoopFileLogger()

    private static let maxBytes = 512 * 1024
    private static let maxMemoryLines = 400
    private static let dirName = "libreloop"
    private static let fileName = "log.txt"

    private let queue = DispatchQueue(label: "org.loopkit.LibreLoop.FileLogger")
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var handle: FileHandle?
    private var bytesWritten: Int = 0
    private var fileURL: URL?

    /// Recent log lines for the in-app activity view. Always mutated on
    /// the main thread so SwiftUI can observe directly.
    @Published public private(set) var recentLines: [String] = []

    private init() {
        queue.async { [weak self] in self?.openIfNeeded() }
    }

    public func append(_ line: String) {
        let stamped = "\(isoFormatter.string(from: Date())) \(line)"
        queue.async { [weak self] in
            guard let self else { return }
            self.openIfNeeded()
            guard let handle = self.handle, let data = (stamped + "\n").data(using: .utf8) else { return }
            handle.write(data)
            self.bytesWritten += data.count
            if self.bytesWritten >= Self.maxBytes {
                self.rotate()
            }
        }
        appendToMemoryBuffer(stamped)
    }

    private func appendToMemoryBuffer(_ stamped: String) {
        if Thread.isMainThread {
            applyMemoryBufferAppend(stamped)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyMemoryBufferAppend(stamped)
            }
        }
    }

    private func applyMemoryBufferAppend(_ stamped: String) {
        recentLines.append(stamped)
        if recentLines.count > Self.maxMemoryLines {
            recentLines.removeFirst(recentLines.count - Self.maxMemoryLines)
        }
    }

    /// Returns the on-disk path so the agent retrieving logs can target it.
    public var currentLogURL: URL? {
        queue.sync { fileURL }
    }

    private func openIfNeeded() {
        if handle != nil { return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent(Self.dirName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.fileName)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        _ = try? h.seekToEnd()
        handle = h
        fileURL = url
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            bytesWritten = size
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0
        guard let url = fileURL else { return }
        let fm = FileManager.default
        let rotated = url.deletingPathExtension().appendingPathExtension("1.txt")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
        openIfNeeded()
    }
}

/// Optional sink that also forwards every `llog` message to Loop's persistent
/// DeviceLog (`logEventForDeviceIdentifier`), so LibreLoop's connection and
/// data events appear in Loop's device logs / Issue Reports like the other CGM
/// managers. The CGM manager registers this via `setLibreLoopDeviceLogSink`.
/// Set once at manager init, then read on every llog — a benign set-once race.
private var libreLoopDeviceLogSink: ((String) -> Void)?

/// Register (or clear) the DeviceLog forwarder used by `llog`.
public func setLibreLoopDeviceLogSink(_ sink: ((String) -> Void)?) {
    libreLoopDeviceLogSink = sink
}

/// Helper that mirrors a single string to the unified OS log (so Console.app
/// still sees it), the LibreLoop file logger, and — when a sink is registered —
/// Loop's persistent DeviceLog.
/// Use this at every call site where we currently do `log.notice("...")`
/// for connection-state events worth retaining.
public func llog(_ message: String,
                 file: String = #fileID,
                 line: Int = #line,
                 category: StaticString = "CGMManager") {
    let tag = "[\(file):\(line)]"
    let osLog = OSLog(subsystem: "org.loopkit.LibreLoop", category: String(describing: category))
    os_log("%{public}@ %{public}@", log: osLog, type: .info, tag, message)
    LibreLoopFileLogger.shared.append("\(tag) \(message)")
    // DeviceLog gets the clean message only — no [file:line] tag, matching the
    // other CGM managers' device-log style (the tag stays in os_log + file log).
    libreLoopDeviceLogSink?(message)
}
