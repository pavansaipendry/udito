import Foundation

/// Saved meetings from Documents/Ears — the in-app history browser's model.
///
/// Listing scans metadata only; transcript bodies are read per-file on demand
/// and cached. A library of hundreds of hour-long meetings must never stall
/// the main thread just to show the list.
final class TranscriptLibrary: ObservableObject {
    struct Meeting: Identifiable, Equatable {
        let id: URL
        let name: String
        let date: Date
    }

    @Published private(set) var meetings: [Meeting] = []

    private var contentCache: [URL: String] = [:]

    func reload() {
        meetings = Self.scan()
        contentCache = [:]
    }

    /// Metadata-only directory scan — cheap regardless of library size.
    static func scan() -> [Meeting] {
        let directory = SessionController.transcriptsDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Meeting(
                    id: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    date: date
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// One meeting's transcript, read on demand and cached.
    func content(_ meeting: Meeting) -> String {
        if let cached = contentCache[meeting.id] { return cached }
        let text = (try? String(contentsOf: meeting.id, encoding: .utf8)) ?? ""
        contentCache[meeting.id] = text
        return text
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.trashItem(at: meeting.id, resultingItemURL: nil)
        contentCache.removeValue(forKey: meeting.id)
        reload()
    }

    /// Instant name-only filter — safe to run per keystroke. Content search
    /// is the caller's job on a background queue (see LibraryView).
    func matching(_ query: String) -> [Meeting] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return meetings }
        return meetings.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}
