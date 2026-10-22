import EventKit

/// Names a new meeting after the calendar event happening now, when the user has turned that on
/// under Settings › Meetings and granted Calendar access. Off by default, so the system prompt
/// appears only after an explicit choice. Nothing is written to the calendar.
@MainActor
enum CalendarTitles {
    static let enabledKey = "calendarTitles"
    private static let store = EKEventStore()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Shows the system prompt once; later calls return the stored answer.
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The title of an event that is under way, or starts within the next ten minutes. The earliest
    /// such event wins, and all-day events are skipped since they rarely name a meeting.
    static func currentEventTitle(now: Date = .now) -> String? {
        guard isEnabled, isAuthorized else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                                 end: now.addingTimeInterval(10 * 60), calendars: nil)
        let title = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }
}
