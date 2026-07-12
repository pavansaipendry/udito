import Foundation

/// Saved meetings from Documents/Ears — the in-app history browser's model.
final class TranscriptLibrary: ObservableObject {
    struct Meeting: Identifiable, Equatable {
        let id: URL
        let name: String
        let date: Date
        let content: String
    }

    @Published private(set) var meetings: [Meeting] = []

    func reload() {
        let directory = SessionController.transcriptsDirectory
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            meetings = []
            return
        }
        meetings = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> Meeting? in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Meeting(
                    id: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    date: date,
                    content: content
                )
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.trashItem(at: meeting.id, resultingItemURL: nil)
        reload()
    }

    func matching(_ query: String) -> [Meeting] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return meetings }
        return meetings.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.content.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
