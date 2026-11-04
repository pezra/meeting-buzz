import CryptoKit
import EventKit

struct Attendee {
    var isCurrentUser: Bool
    var type: EKParticipantType
    var status: EKParticipantStatus
}

struct CalendarEvent {
    var id: String
    var title: String
    var start: Date
    var isAllDay: Bool
    var isCanceled: Bool
    var attendees: [Attendee]
}

struct Reminder: Identifiable, Equatable {
    var id: UUID
    var title: String
    var eventStart: Date
    var fireDate: Date
}

enum ReminderPolicy {
    static let leadTime: TimeInterval = 30
    static let lookahead: TimeInterval = 14 * 24 * 60 * 60
    /// AlarmKit enforces an undocumented limit, so only hold alarms for the soonest events.
    static let maxAlarms = 60

    /// Stable across refreshes. Moving or renaming an event changes it, which replaces the alarm.
    static func alarmID(for event: CalendarEvent) -> UUID {
        let key = "\(event.id)|\(event.start.timeIntervalSince1970)|\(event.title)"
        return SHA256.hash(data: Data(key.utf8)).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    static func involvesAnotherPerson(_ event: CalendarEvent) -> Bool {
        event.attendees.contains { attendee in
            !attendee.isCurrentUser && attendee.type != .room && attendee.type != .resource
        }
    }

    static func shouldRemind(_ event: CalendarEvent) -> Bool {
        guard !event.isAllDay, !event.isCanceled else { return false }
        let declined = event.attendees.contains { $0.isCurrentUser && $0.status == .declined }
        return !declined && involvesAnotherPerson(event)
    }

    static func reminders(for events: [CalendarEvent], now: Date) -> [Reminder] {
        let upcoming = events
            .filter(shouldRemind)
            .map { event in
                Reminder(
                    id: alarmID(for: event),
                    title: event.title,
                    eventStart: event.start,
                    fireDate: event.start.addingTimeInterval(-leadTime)
                )
            }
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
        return Array(upcoming.prefix(maxAlarms))
    }
}
