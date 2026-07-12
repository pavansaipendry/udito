import Foundation

/// Reference documents the user attaches for a meeting (briefs, agendas,
/// notes). Their content rides along with every Ask AI question so Claude can
/// answer from the documents as well as the live transcript.
///
/// PDFs go to the API natively (base64 document blocks); Word/RTF/HTML are
/// converted to text locally via macOS `textutil`; plain-text files are read
/// directly.
final class MeetingDocuments: ObservableObject {
    struct Document: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let kind: Kind

        enum Kind: Equatable {
            case pdf(Data)
            case text(String)
        }
    }

    @Published private(set) var documents: [Document] = []
    @Published var warning: String?

    private static let maxPDFBytes = 15 * 1024 * 1024
    private static let maxTotalPDFBytes = 25 * 1024 * 1024
    private static let maxTextChars = 300_000
    private static let textutilExtensions: Set<String> = [
        "doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive",
    ]

    func attach(urls: [URL]) {
        warning = nil
        var failures: [String] = []
        for url in urls {
            do {
                try attachOne(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let message = failures.joined(separator: " · ")
            warning = message
            EarsLog.error("Document attach failed: \(message)")
        }
    }

    func remove(_ id: UUID) {
        documents.removeAll { $0.id == id }
    }

    func clear() {
        documents.removeAll()
        warning = nil
    }

    /// Claude Messages API document content blocks, with a cache breakpoint on
    /// the last one — documents are a stable prefix across questions, so
    /// repeated asks read them from the prompt cache instead of re-billing.
    func contentBlocks() -> [[String: Any]] {
        var blocks: [[String: Any]] = documents.map { document in
            switch document.kind {
            case .pdf(let data):
                return [
                    "type": "document",
                    "title": document.name,
                    "source": [
                        "type": "base64",
                        "media_type": "application/pdf",
                        "data": data.base64EncodedString(),
                    ],
                ]
            case .text(let text):
                return [
                    "type": "document",
                    "title": document.name,
                    "source": [
                        "type": "text",
                        "media_type": "text/plain",
                        "data": text,
                    ],
                ]
            }
        }
        if !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
        }
        return blocks
    }

    // MARK: - Reading files

    private func attachOne(_ url: URL) throws {
        let name = url.lastPathComponent
        guard !documents.contains(where: { $0.name == name }) else { return }
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxPDFBytes else {
                throw EarsError("PDF is larger than 15 MB.")
            }
            guard totalPDFBytes + data.count <= Self.maxTotalPDFBytes else {
                throw EarsError("Attached PDFs exceed 25 MB total — remove one first.")
            }
            documents.append(Document(name: name, kind: .pdf(data)))
            return
        }

        let raw: String
        if Self.textutilExtensions.contains(ext) {
            raw = try Self.extractText(from: url)
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            raw = text
        } else {
            throw EarsError("Unsupported file type — use PDF, Word, text, or markdown.")
        }

        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EarsError("The file has no readable text.")
        }
        if trimmed.count > Self.maxTextChars {
            trimmed = String(trimmed.prefix(Self.maxTextChars))
        }
        documents.append(Document(name: name, kind: .text(trimmed)))
    }

    private var totalPDFBytes: Int {
        documents.reduce(0) { total, document in
            if case .pdf(let data) = document.kind {
                return total + data.count
            }
            return total
        }
    }

    /// Word/RTF/HTML → plain text via the system converter.
    private static func extractText(from url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            throw EarsError("Could not extract text from this file.")
        }
        return text
    }
}
