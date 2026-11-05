import AlarmKit
import BackgroundTasks
import EventKit
import Observation
import SwiftUI

struct BuzzMetadata: AlarmMetadata {}

@MainActor
@Observable
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    static let refreshTaskID = "org.barelyenough.MeetingBuzz.refresh"
    static let overnightTaskID = "org.barelyenough.MeetingBuzz.overnight"
    private static let testAlarmID = UUID(uuidString: "5D1A7C52-0B7E-4C39-9E55-3F0A6B2C1D10")!
    private static let syncWait = Duration.seconds(10)
    private static let backgroundUpdateDateKey = "lastBackgroundUpdateDate"
    private static let backgroundUpdateSourceKey = "lastBackgroundUpdateSource"

    private(set) var reminders: [Reminder] = []
    private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    private(set) var alarmAccess = AlarmManager.shared.authorizationState
    private(set) var errorMessage: String?
    private(set) var lastBackgroundUpdate = UserDefaults.standard.object(forKey: backgroundUpdateDateKey) as? Date
    private(set) var lastBackgroundSource = UserDefaults.standard.string(forKey: backgroundUpdateSourceKey)

    private let store = EKEventStore()
    private let alarms = AlarmManager.shared
    private var isRefreshing = false
    private var needsAnotherRefresh = false

    func requestPermissions() async {
        do {
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try await store.requestFullAccessToEvents()
            }
            if alarms.authorizationState == .notDetermined {
                _ = try await AlarmManager.shared.requestAuthorization()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Brings scheduled alarms in line with the calendar. Calls made during a refresh are coalesced into one more pass.
    func refresh() async {
        guard !isRefreshing else {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsAnotherRefresh = false
            await syncAlarms()
        } while needsAnotherRefresh
    }

    /// Asks iOS to pull from calendar accounts if it thinks they're out of date. iOS doesn't report the outcome,
    /// so this can't be awaited. Don't call this when handling EKEventStoreChanged, since a sync posts that notification.
    func requestCalendarSync() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        store.refreshSourcesIfNecessary()
    }

    /// Refreshes on behalf of something other than the user opening the app, and records that it worked.
    func backgroundRefresh(source: String) async {
        scheduleBackgroundRefresh()
        // Apply what's already on the phone first, in case iOS suspends the app during the wait.
        await refresh()
        requestCalendarSync()
        try? await Task.sleep(for: Self.syncWait)
        await refresh()
        guard errorMessage == nil, calendarAccess == .fullAccess, alarmAccess == .authorized else { return }
        let now = Date()
        lastBackgroundUpdate = now
        lastBackgroundSource = source
        UserDefaults.standard.set(now, forKey: Self.backgroundUpdateDateKey)
        UserDefaults.standard.set(source, forKey: Self.backgroundUpdateSourceKey)
    }

    /// SwiftUI's backgroundTask modifier has no processing task, so this one is registered directly. Must run before launch finishes.
    static func registerOvernightRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: overnightTaskID, using: .main) { task in
            MainActor.assumeIsolated {
                shared.runOvernightRefresh(task)
            }
        }
    }

    private func runOvernightRefresh(_ task: BGTask) {
        let work = Task {
            await backgroundRefresh(source: "Overnight")
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    func scheduleTestBuzz() async {
        try? alarms.cancel(id: Self.testAlarmID)
        do {
            try await schedule(id: Self.testAlarmID, title: "MeetingBuzz test", at: Date(timeIntervalSinceNow: 10))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)

        let overnight = BGProcessingTaskRequest(identifier: Self.overnightTaskID)
        overnight.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(overnight)
    }

    private func syncAlarms() async {
        errorMessage = nil
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        alarmAccess = alarms.authorizationState
        guard calendarAccess == .fullAccess, alarmAccess == .authorized else {
            reminders = []
            return
        }

        let now = Date()
        let desired = ReminderPolicy.reminders(for: fetchEvents(from: now), now: now)

        do {
            let existing = try alarms.alarms
            let desiredIDs = Set(desired.map(\.id))
            // Only alarms still waiting to fire: cancelling one that's ringing would stop it before it's dismissed.
            for alarm in existing where alarm.state == .scheduled && alarm.id != Self.testAlarmID && !desiredIDs.contains(alarm.id) {
                try alarms.cancel(id: alarm.id)
            }

            let existingIDs = Set(existing.map(\.id))
            for reminder in desired where !existingIDs.contains(reminder.id) {
                try await schedule(id: reminder.id, title: "\(reminder.title) starts in 30 seconds", at: reminder.fireDate)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        reminders = desired
    }

    private func fetchEvents(from start: Date) -> [CalendarEvent] {
        let end = start.addingTimeInterval(ReminderPolicy.lookahead)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.calendarItemIdentifier,
                title: event.title ?? "Meeting",
                start: event.startDate,
                isAllDay: event.isAllDay,
                isCanceled: event.status == .canceled,
                attendees: (event.attendees ?? []).map {
                    Attendee(isCurrentUser: $0.isCurrentUser, type: $0.participantType, status: $0.participantStatus)
                }
            )
        }
    }

    private func schedule(id: UUID, title: String, at date: Date) async throws {
        let alert = AlarmPresentation.Alert(title: "\(title)")
        let attributes = AlarmAttributes<BuzzMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: .blue)
        // A silent sound, so the alarm vibrates without making noise.
        let configuration = AlarmManager.AlarmConfiguration<BuzzMetadata>.alarm(
            schedule: .fixed(date),
            attributes: attributes,
            sound: .named("silence.caf")
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }
}
