import Foundation

// MARK: - AeroLog

/// Lightweight file-based debug logger.
/// Log file: ~/Library/Logs/AeroSpace/debug.log
/// Rotates (→ debug.log.old) when the file exceeds ~4 MB.
/// All writes happen on the caller's thread (always MainActor in practice).
@MainActor
enum AeroLog {
    private static let maxFileSize: Int = 4 * 1024 * 1024 // 4 MB

    static let logFileURL: URL = {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appending(path: "Logs/AeroSpace", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appending(path: "debug.log")
    }()

    private static var fileHandle: FileHandle? = {
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: url)
    }()

    // MARK: Public API

    static func log(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        write(line)
    }

    /// Write a clearly-visible marker so you can identify the moment in the log
    /// before a bug occurred. Bind `aerospace debug-log-marker` to a key.
    static func marker(_ label: String = "") {
        let tag = label.isEmpty ? "" : " \(label)"
        let line = "\n[\(timestamp())] ════════════ MARKER\(tag) ════════════\n\n"
        write(line)
    }

    // MARK: Private

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        guard let fh = fileHandle else { return }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int,
              size > maxFileSize
        else { return }

        let oldURL = logFileURL.deletingLastPathComponent().appending(path: "debug.log.old")
        fileHandle?.closeFile()
        fileHandle = nil
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: logFileURL, to: oldURL)
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        write("[\(timestamp())] --- log rotated (previous saved as debug.log.old) ---\n")
    }
}

// MARK: - Convenience top-level function

@MainActor
func aeroLog(_ message: String) {
    AeroLog.log(message)
}
