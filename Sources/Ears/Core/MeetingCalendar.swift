import EventKit
import Foundation

/// Names transcripts after the calendar event that was happening — "Weekly
/// design sync" beats "Meeting 2026-07-11 09.30". Fully optional: the first
/// save asks for calendar access once; declined or empty calendars simply
/// fall back to the date-based name.
enum MeetingCalendar {
    private static let store = EKEventStore()

    /// Calls back with the title of the event overlapping the session (or
    /// nil). Async because the first use triggers the permission prompt.
    static func eventTitle(around startedAt: Date, completion: @escaping (String?) -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                completion(granted ? lookUp(around: startedAt) : nil)
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    private static func lookUp(around startedAt: Date) -> String? {
        // Any event overlapping the first 10 minutes of the session.
        let predicate = store.predicateForEvents(
            withStart: startedAt.addingTimeInterval(-15 * 60),
            end: startedAt.addingTimeInterval(10 * 60),
            calendars: nil
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > startedAt }
            .sorted { $0.startDate > $1.startDate }
        guard let title = events.first?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return sanitized(title)
    }

    /// Safe for a file name.
    private static func sanitized(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(80))
    }
}
