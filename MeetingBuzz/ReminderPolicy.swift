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
    var leadTime: TimeInterval

    var fireDate: Date {
        eventStart.addingTimeInterval(-leadTime)
    }

    var alertTitle: String {
        "\(title) starts in \(ReminderPolicy.describe(leadTime: leadTime))"
    }
}

struct ExistingAlarm {
    var id: UUID
    var isWaitingToFire: Bool
    var fireDate: Date? = nil
}

enum ReminderPolicy {
    static let defaultLeadTime: TimeInterval = 30
    static let leadTimeOptions: [TimeInterval] = [30, 60, 120, 300, 600, 900]
    static let lookaheadDays = 14
    static let lookahead = TimeInterval(lookaheadDays) * 24 * 60 * 60
    /// AlarmKit enforces an undocumented limit, so only hold alarms for the soonest events.
    static let maxAlarms = 60

    static func describe(leadTime: TimeInterval) -> String {
        Duration.seconds(leadTime).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

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

    static func reminders(
        for events: [CalendarEvent],
        now: Date,
        leadTime: TimeInterval = defaultLeadTime
    ) -> [Reminder] {
        let upcoming = Dictionary(grouping: events.filter(shouldRemind), by: \.start)
            .map { start, group in
                let ordered = group.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
                return Reminder(
                    id: alarmID(for: ordered),
                    title: combinedTitle(for: ordered),
                    eventStart: start,
                    leadTime: leadTime
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
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        let existingIDs = Set(existing.map(\.id))
        // Only alarms still waiting to fire: cancelling one that's ringing would stop it before it's dismissed.
        let waiting = existing.filter(\.isWaitingToFire)
        let stale = canCancel
            ? waiting.filter { !keeping.contains($0.id) && desiredByID[$0.id] == nil }.map(\.id)
            : []
        // Left over from an earlier lead time. The event is still on the calendar, so this doesn't wait for canCancel.
        let retimed = waiting.filter { alarm in
            guard let current = alarm.fireDate, let wanted = desiredByID[alarm.id]?.fireDate else { return false }
            return abs(current.timeIntervalSince(wanted)) >= 1
        }.map(\.id)
        let replacing = Set(retimed)
        return (stale + retimed, desired.filter { !existingIDs.contains($0.id) || replacing.contains($0.id) })
    }
}
