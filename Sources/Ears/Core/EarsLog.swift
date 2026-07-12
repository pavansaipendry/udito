import Foundation
import os

struct EarsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum EarsLog {
    private static let logger = Logger(subsystem: "com.pavansai.ears", category: "app")
    private static let queue = DispatchQueue(label: "ears.log", qos: .utility)
    private static let timestamp = ISO8601DateFormatter()

    private static let maxLogBytes = 5 << 20

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Ears.log")
        // Rotate once per launch so the log never grows unbounded.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maxLogBytes {
            let old = dir.appendingPathComponent("Ears.log.old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        return url
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    private static func append(_ level: String, _ message: String) {
        queue.async {
            let line = "\(timestamp.string(from: Date())) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            // Throwing (Swift-error) FileHandle APIs only — the legacy
            // seekToEndOfFile/write pair raises an uncatchable NSException on
            // I/O failure (e.g. disk full), which would crash the app from
            // its own logger.
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {}
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
