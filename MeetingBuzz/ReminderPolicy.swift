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

    var fireDate: Date {
        eventStart.addingTimeInterval(-ReminderPolicy.leadTime)
    }

    var alertTitle: String {
        "\(title) starts in \(Int(ReminderPolicy.leadTime)) seconds"
    }
}

struct ExistingAlarm {
    var id: UUID
    var isWaitingToFire: Bool
}

enum ReminderPolicy {
    static let leadTime: TimeInterval = 30
    static let lookaheadDays = 14
    static let lookahead = TimeInterval(lookaheadDays) * 24 * 60 * 60
    /// AlarmKit enforces an undocumented limit, so only hold alarms for the soonest events.
    static let maxAlarms = 60

    /// Stable across refreshes. Moving, renaming, adding or removing an event changes it, which replaces the alarm.
    static func alarmID(for events: [CalendarEvent]) -> UUID {
        let key = events
            .map { "\($0.id)|\($0.start.timeIntervalSince1970)|\($0.title)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(key.utf8)).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    private static func combinedTitle(for events: [CalendarEvent]) -> String {
        let others = events.count - 1
        return others > 0 ? "\(events[0].title) + \(others) more" : events[0].title
    }

    private static func involvesAnotherPerson(_ event: CalendarEvent) -> Bool {
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
        let upcoming = Dictionary(grouping: events.filter(shouldRemind), by: \.start)
            .map { start, group in
                let ordered = group.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
                return Reminder(
                    id: alarmID(for: ordered),
                    title: combinedTitle(for: ordered),
                    eventStart: start
                )
            }
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
        return Array(upcoming.prefix(maxAlarms))
    }

    /// What it takes to bring the alarms in line with the calendar. Pass canCancel as false to only add alarms, and
    /// use keeping for alarms that don't come from the calendar.
    static func alarmChanges(
        desired: [Reminder],
        existing: [ExistingAlarm],
        canCancel: Bool,
        keeping: Set<UUID>
    ) -> (cancel: [UUID], schedule: [Reminder]) {
        let desiredIDs = Set(desired.map(\.id))
        let existingIDs = Set(existing.map(\.id))
        // Only alarms still waiting to fire: cancelling one that's ringing would stop it before it's dismissed.
        let cancel = canCancel
            ? existing.filter { $0.isWaitingToFire && !keeping.contains($0.id) && !desiredIDs.contains($0.id) }.map(\.id)
            : []
        return (cancel, desired.filter { !existingIDs.contains($0.id) })
    }
}
