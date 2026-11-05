import EventKit
import Foundation
import Testing
@testable import MeetingBuzz

private let me = Attendee(isCurrentUser: true, type: .person, status: .accepted)
private let colleague = Attendee(isCurrentUser: false, type: .person, status: .accepted)

struct ReminderPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        id: String = "a",
        title: String = "Sync",
        startingIn seconds: TimeInterval = 3600,
        isAllDay: Bool = false,
        isCanceled: Bool = false,
        attendees: [Attendee] = [colleague]
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            start: now.addingTimeInterval(seconds),
            isAllDay: isAllDay,
            isCanceled: isCanceled,
            attendees: attendees
        )
    }

    private func reminder(_ id: UUID) -> Reminder {
        Reminder(id: id, title: "Sync", eventStart: now, leadTime: 30)
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
        let reminder = try #require(ReminderPolicy.reminders(for: [event()], now: now).first)
        #expect(reminder.eventStart.timeIntervalSince(reminder.fireDate) == 30)
        #expect(reminder.alertTitle == "Sync starts in 30 seconds")
    }

    @Test func firesAtTheConfiguredLeadTime() throws {
        let reminder = try #require(ReminderPolicy.reminders(for: [event()], now: now, leadTime: 300).first)
        #expect(reminder.eventStart.timeIntervalSince(reminder.fireDate) == 300)
        #expect(reminder.alertTitle == "Sync starts in 5 minutes")
    }

    @Test func describesASingleMinuteInTheSingular() {
        #expect(ReminderPolicy.describe(leadTime: 60) == "1 minute")
    }

    @Test func alarmIDDoesNotDependOnLeadTime() throws {
        let short = try #require(ReminderPolicy.reminders(for: [event()], now: now, leadTime: 30).first)
        let long = try #require(ReminderPolicy.reminders(for: [event()], now: now, leadTime: 300).first)
        #expect(short.id == long.id)
    }

    @Test func skipsEventsWhoseBuzzTimeHasPassedAtTheConfiguredLeadTime() {
        let reminders = ReminderPolicy.reminders(for: [event(startingIn: 120)], now: now, leadTime: 300)
        #expect(reminders.isEmpty)
    }

    @Test func skipsEventsWhoseBuzzTimeHasPassed() {
        let tooLate = event(startingIn: 30)
        let justInTime = event(id: "b", startingIn: 31)
        let reminders = ReminderPolicy.reminders(for: [tooLate, justInTime], now: now)
        #expect(reminders.map(\.eventStart) == [justInTime.start])
    }

    @Test func recurringOccurrencesGetDistinctIDs() {
        let first = event(id: "weekly", startingIn: 3600)
        let second = event(id: "weekly", startingIn: 7200)
        let reminders = ReminderPolicy.reminders(for: [first, second], now: now)
        #expect(Set(reminders.map(\.id)).count == 2)
    }

    @Test func alarmIDIsStableUntilTheEventChanges() {
        let original = event()
        #expect(ReminderPolicy.alarmID(for: [original]) == ReminderPolicy.alarmID(for: [event(attendees: [me, colleague])]))
        #expect(ReminderPolicy.alarmID(for: [original]) != ReminderPolicy.alarmID(for: [event(title: "Renamed")]))
        #expect(ReminderPolicy.alarmID(for: [original]) != ReminderPolicy.alarmID(for: [event(startingIn: 7200)]))
    }

    @Test func eventsStartingTogetherShareOneReminder() throws {
        let review = event(id: "a", title: "Review")
        let standup = event(id: "b", title: "Standup")
        let later = event(id: "c", startingIn: 7200)

        let reminders = ReminderPolicy.reminders(for: [standup, later, review], now: now)

        #expect(reminders.count == 2)
        let combined = try #require(reminders.first)
        #expect(combined.title == "Review + 1 more")
        #expect(combined.eventStart == review.start)
    }

    @Test func combinedReminderIgnoresEventsThatDoNotQualify() {
        let solo = event(id: "solo", attendees: [me])
        let meeting = event(id: "meeting")
        let reminders = ReminderPolicy.reminders(for: [solo, meeting], now: now)
        #expect(reminders.map(\.title) == ["Sync"])
    }

    @Test func combinedAlarmIDDoesNotDependOnCalendarOrder() {
        let first = event(id: "a")
        let second = event(id: "b")
        let forward = ReminderPolicy.reminders(for: [first, second], now: now)
        let backward = ReminderPolicy.reminders(for: [second, first], now: now)
        #expect(forward == backward)
    }

    @Test func addingAnEventToAGroupChangesItsAlarmID() throws {
        let first = event(id: "a")
        let second = event(id: "b")
        let alone = try #require(ReminderPolicy.reminders(for: [first], now: now).first)
        let together = try #require(ReminderPolicy.reminders(for: [first, second], now: now).first)
        #expect(alone.id != together.id)
    }

    @Test func keepsOnlyTheSoonestWithinTheAlarmLimit() {
        let events = (1...100).reversed().map { index in
            event(id: "\(index)", startingIn: TimeInterval(index) * 60)
        }
        let reminders = ReminderPolicy.reminders(for: events, now: now)
        #expect(reminders.count == ReminderPolicy.maxAlarms)
        #expect(reminders.first?.eventStart == now.addingTimeInterval(60))
        #expect(reminders == reminders.sorted { $0.fireDate < $1.fireDate })
    }

    @Test func schedulesOnlyAlarmsThatDoNotExistYet() {
        let existing = UUID()
        let new = UUID()
        let changes = ReminderPolicy.alarmChanges(
            desired: [reminder(existing), reminder(new)],
            existing: [ExistingAlarm(id: existing, isWaitingToFire: true)],
            canCancel: true,
            keeping: []
        )
        #expect(changes.schedule.map(\.id) == [new])
        #expect(changes.cancel.isEmpty)
    }

    @Test func cancelsWaitingAlarmsThatAreNoLongerWanted() {
        let stale = UUID()
        let changes = ReminderPolicy.alarmChanges(
            desired: [],
            existing: [ExistingAlarm(id: stale, isWaitingToFire: true)],
            canCancel: true,
            keeping: []
        )
        #expect(changes.cancel == [stale])
    }

    @Test func holdingCancellationsStillSchedulesNewAlarms() {
        let new = UUID()
        let changes = ReminderPolicy.alarmChanges(
            desired: [reminder(new)],
            existing: [ExistingAlarm(id: UUID(), isWaitingToFire: true)],
            canCancel: false,
            keeping: []
        )
        #expect(changes.cancel.isEmpty)
        #expect(changes.schedule.map(\.id) == [new])
    }

    @Test func neverCancelsARingingAlarm() {
        let changes = ReminderPolicy.alarmChanges(
            desired: [],
            existing: [ExistingAlarm(id: UUID(), isWaitingToFire: false)],
            canCancel: true,
            keeping: []
        )
        #expect(changes.cancel.isEmpty)
    }

    @Test func ringingAlarmIsNotScheduledAgain() {
        let ringing = UUID()
        let changes = ReminderPolicy.alarmChanges(
            desired: [reminder(ringing)],
            existing: [ExistingAlarm(id: ringing, isWaitingToFire: false)],
            canCancel: true,
            keeping: []
        )
        #expect(changes.schedule.isEmpty)
    }

    @Test func replacesAlarmsLeftFromAnEarlierLeadTime() {
        let id = UUID()
        let wanted = reminder(id)
        let changes = ReminderPolicy.alarmChanges(
            desired: [wanted],
            existing: [ExistingAlarm(id: id, isWaitingToFire: true, fireDate: wanted.fireDate.addingTimeInterval(-270))],
            canCancel: true,
            keeping: []
        )
        #expect(changes.cancel == [id])
        #expect(changes.schedule == [wanted])
    }

    @Test func holdingCancellationsStillReplacesAlarmsLeftFromAnEarlierLeadTime() {
        let id = UUID()
        let wanted = reminder(id)
        let changes = ReminderPolicy.alarmChanges(
            desired: [wanted],
            existing: [ExistingAlarm(id: id, isWaitingToFire: true, fireDate: wanted.fireDate.addingTimeInterval(-270))],
            canCancel: false,
            keeping: []
        )
        #expect(changes.cancel == [id])
        #expect(changes.schedule == [wanted])
    }

    @Test func leavesAlarmsAlreadyAtTheRightTime() {
        let id = UUID()
        let wanted = reminder(id)
        let changes = ReminderPolicy.alarmChanges(
            desired: [wanted],
            existing: [ExistingAlarm(id: id, isWaitingToFire: true, fireDate: wanted.fireDate)],
            canCancel: true,
            keeping: []
        )
        #expect(changes.cancel.isEmpty)
        #expect(changes.schedule.isEmpty)
    }

    @Test func changingLeadTimeDoesNotStopARingingAlarm() {
        let id = UUID()
        let wanted = reminder(id)
        let changes = ReminderPolicy.alarmChanges(
            desired: [wanted],
            existing: [ExistingAlarm(id: id, isWaitingToFire: false, fireDate: wanted.fireDate.addingTimeInterval(-270))],
            canCancel: true,
            keeping: []
        )
        #expect(changes.cancel.isEmpty)
        #expect(changes.schedule.isEmpty)
    }

    @Test func leavesAlarmsThatDoNotComeFromTheCalendar() {
        let test = UUID()
        let changes = ReminderPolicy.alarmChanges(
            desired: [],
            existing: [ExistingAlarm(id: test, isWaitingToFire: true)],
            canCancel: true,
            keeping: [test]
        )
        #expect(changes.cancel.isEmpty)
    }
}
