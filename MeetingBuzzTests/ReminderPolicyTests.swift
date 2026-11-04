import EventKit
import Foundation
import Testing
@testable import MeetingBuzz

struct ReminderPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = Attendee(isCurrentUser: true, type: .person, status: .accepted)
    private let colleague = Attendee(isCurrentUser: false, type: .person, status: .accepted)

    private func event(
        id: String = "a",
        startingIn seconds: TimeInterval = 3600,
        isAllDay: Bool = false,
        isCanceled: Bool = false,
        attendees: [Attendee]
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Sync",
            start: now.addingTimeInterval(seconds),
            isAllDay: isAllDay,
            isCanceled: isCanceled,
            attendees: attendees
        )
    }

    @Test func remindsWhenAnotherPersonAttends() {
        #expect(ReminderPolicy.shouldRemind(event(attendees: [me, colleague])))
    }

    @Test func ignoresEventsWithNoAttendees() {
        #expect(!ReminderPolicy.shouldRemind(event(attendees: [])))
    }

    @Test func ignoresEventsWhereIAmTheOnlyAttendee() {
        #expect(!ReminderPolicy.shouldRemind(event(attendees: [me])))
    }

    @Test func roomsAndResourcesAreNotPeople() {
        let room = Attendee(isCurrentUser: false, type: .room, status: .accepted)
        let projector = Attendee(isCurrentUser: false, type: .resource, status: .accepted)
        #expect(!ReminderPolicy.shouldRemind(event(attendees: [me, room, projector])))
    }

    @Test func unknownParticipantTypeCountsAsAPerson() {
        let unknown = Attendee(isCurrentUser: false, type: .unknown, status: .unknown)
        #expect(ReminderPolicy.shouldRemind(event(attendees: [me, unknown])))
    }

    @Test func ignoresDeclinedCanceledAndAllDayEvents() {
        let declined = Attendee(isCurrentUser: true, type: .person, status: .declined)
        #expect(!ReminderPolicy.shouldRemind(event(attendees: [declined, colleague])))
        #expect(!ReminderPolicy.shouldRemind(event(isCanceled: true, attendees: [me, colleague])))
        #expect(!ReminderPolicy.shouldRemind(event(isAllDay: true, attendees: [me, colleague])))
    }

    @Test func firesThirtySecondsBeforeStart() throws {
        let reminder = try #require(ReminderPolicy.reminders(for: [event(attendees: [colleague])], now: now).first)
        #expect(reminder.eventStart.timeIntervalSince(reminder.fireDate) == 30)
    }

    @Test func skipsEventsWhoseBuzzTimeHasPassed() {
        let tooLate = event(startingIn: 30, attendees: [colleague])
        let justInTime = event(id: "b", startingIn: 31, attendees: [colleague])
        let reminders = ReminderPolicy.reminders(for: [tooLate, justInTime], now: now)
        #expect(reminders.map(\.eventStart) == [justInTime.start])
    }

    @Test func recurringOccurrencesGetDistinctIDs() {
        let first = event(id: "weekly", startingIn: 3600, attendees: [colleague])
        let second = event(id: "weekly", startingIn: 7200, attendees: [colleague])
        let reminders = ReminderPolicy.reminders(for: [first, second], now: now)
        #expect(Set(reminders.map(\.id)).count == 2)
    }

    @Test func alarmIDIsStableUntilTheEventChanges() {
        let original = event(attendees: [colleague])
        var renamed = original
        renamed.title = "Renamed"
        #expect(ReminderPolicy.alarmID(for: [original]) == ReminderPolicy.alarmID(for: [event(attendees: [me, colleague])]))
        #expect(ReminderPolicy.alarmID(for: [original]) != ReminderPolicy.alarmID(for: [renamed]))
        #expect(ReminderPolicy.alarmID(for: [original]) != ReminderPolicy.alarmID(for: [event(startingIn: 7200, attendees: [colleague])]))
    }

    @Test func eventsStartingTogetherShareOneReminder() throws {
        var review = event(id: "a", attendees: [colleague])
        review.title = "Review"
        var standup = event(id: "b", attendees: [colleague])
        standup.title = "Standup"
        let later = event(id: "c", startingIn: 7200, attendees: [colleague])

        let reminders = ReminderPolicy.reminders(for: [standup, later, review], now: now)

        #expect(reminders.count == 2)
        let combined = try #require(reminders.first)
        #expect(combined.title == "Review + 1 more")
        #expect(combined.eventStart == review.start)
    }

    @Test func combinedReminderIgnoresEventsThatDoNotQualify() {
        let solo = event(id: "solo", attendees: [me])
        let meeting = event(id: "meeting", attendees: [colleague])
        let reminders = ReminderPolicy.reminders(for: [solo, meeting], now: now)
        #expect(reminders.map(\.title) == ["Sync"])
    }

    @Test func combinedAlarmIDDoesNotDependOnCalendarOrder() {
        let first = event(id: "a", attendees: [colleague])
        let second = event(id: "b", attendees: [colleague])
        let forward = ReminderPolicy.reminders(for: [first, second], now: now)
        let backward = ReminderPolicy.reminders(for: [second, first], now: now)
        #expect(forward == backward)
    }

    @Test func addingAnEventToAGroupChangesItsAlarmID() throws {
        let first = event(id: "a", attendees: [colleague])
        let second = event(id: "b", attendees: [colleague])
        let alone = try #require(ReminderPolicy.reminders(for: [first], now: now).first)
        let together = try #require(ReminderPolicy.reminders(for: [first, second], now: now).first)
        #expect(alone.id != together.id)
    }

    @Test func keepsOnlyTheSoonestWithinTheAlarmLimit() {
        let events = (1...100).reversed().map { index in
            event(id: "\(index)", startingIn: TimeInterval(index) * 60, attendees: [colleague])
        }
        let reminders = ReminderPolicy.reminders(for: events, now: now)
        #expect(reminders.count == ReminderPolicy.maxAlarms)
        #expect(reminders.first?.eventStart == now.addingTimeInterval(60))
        #expect(reminders == reminders.sorted { $0.fireDate < $1.fireDate })
    }
}
