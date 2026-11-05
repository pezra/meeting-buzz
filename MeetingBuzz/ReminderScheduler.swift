import AlarmKit
import BackgroundTasks
import EventKit
import SwiftUI

struct BuzzMetadata: AlarmMetadata {}

@MainActor
@Observable
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    static let refreshTaskID = "org.barelyenough.MeetingBuzz.refresh"
    private static let overnightTaskID = "org.barelyenough.MeetingBuzz.overnight"
    private static let testAlarmID = UUID(uuidString: "5D1A7C52-0B7E-4C39-9E55-3F0A6B2C1D10")!
    /// iOS doesn't report when a sync ends, so it's assumed over if nothing changes for this long after requesting one...
    private static let syncWait = Duration.seconds(10)
    /// ...or for this long after the calendar last changed.
    private static let changeSettleTime = Duration.seconds(5)
    /// Background runs get about 30 seconds, so they stop waiting for a busy sync after this long.
    private static let maxBackgroundWait = Duration.seconds(20)
    private static let backgroundUpdateDateKey = "lastBackgroundUpdateDate"
    private static let backgroundUpdateSourceKey = "lastBackgroundUpdateSource"
    private static let leadTimeKey = "leadTime"

    private(set) var leadTime = UserDefaults.standard.object(forKey: leadTimeKey) as? TimeInterval ?? ReminderPolicy.defaultLeadTime
    private(set) var reminders: [Reminder] = []
    private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    private(set) var alarmAccess = AlarmManager.shared.authorizationState
    /// Why the last update failed. Every update replaces it.
    private(set) var errorMessage: String?
    /// Why a permission request or test buzz failed. Kept separate so the next update doesn't wipe it before it's seen.
    private(set) var actionErrorMessage: String?
    private(set) var lastBackgroundUpdate = UserDefaults.standard.object(forKey: backgroundUpdateDateKey) as? Date
    private(set) var lastBackgroundSource = UserDefaults.standard.string(forKey: backgroundUpdateSourceKey)

    private var hasRequiredAccess: Bool {
        calendarAccess == .fullAccess && alarmAccess == .authorized
    }

    private let store = EKEventStore()
    private let alarms = AlarmManager.shared
    private var refreshTask: Task<Bool, Never>?
    private var needsAnotherRefresh = false
    private var cancellationsHeldUntil = ContinuousClock.now
    private var settleTask: Task<Void, Never>?

    private init() {
        // Registered here rather than in the UI, because a background launch may never create the UI.
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.calendarDidChange()
            }
        }
    }

    func requestPermissions() async {
        actionErrorMessage = nil
        do {
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try await store.requestFullAccessToEvents()
            }
            if alarms.authorizationState == .notDetermined {
                _ = try await AlarmManager.shared.requestAuthorization()
            }
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    /// Applies to future alarms and, through the refresh, to the ones already scheduled.
    func setLeadTime(_ newValue: TimeInterval) {
        leadTime = newValue
        UserDefaults.standard.set(newValue, forKey: Self.leadTimeKey)
        Task { await refresh() }
    }

    /// Brings scheduled alarms in line with the calendar and returns whether that worked. Calls made during a refresh
    /// are coalesced into one more pass, and wait for it to finish.
    @discardableResult
    private func refresh() async -> Bool {
        if let refreshTask {
            needsAnotherRefresh = true
            return await refreshTask.value
        }
        let task = Task {
            defer { refreshTask = nil }
            var succeeded: Bool
            repeat {
                needsAnotherRefresh = false
                succeeded = await syncAlarms()
            } while needsAnotherRefresh
            return succeeded
        }
        refreshTask = task
        return await task.value
    }

    /// Asks iOS to pull from calendar accounts if it thinks they're out of date, then refreshes. Don't call this when
    /// the calendar changes, since a sync causes that. Use refresh() there.
    func syncAndRefresh() async {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            store.refreshSourcesIfNecessary()
            holdCancellations(for: Self.syncWait)
        }
        await refresh()
    }

    private func calendarDidChange() {
        holdCancellations(for: Self.changeSettleTime)
        Task { await refresh() }
    }

    /// The calendar can look incomplete during a sync, and an event missing from it would lose its alarm. So until the
    /// calendar settles, refreshes only add alarms, and one more refresh after that does any cancelling.
    private func holdCancellations(for duration: Duration) {
        let until = ContinuousClock.now + duration
        cancellationsHeldUntil = until
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(until: until)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func waitForCalendarToSettle() async {
        let deadline = ContinuousClock.now + Self.maxBackgroundWait
        // Checks again after waking, because a calendar change can move the hold.
        while !Task.isCancelled {
            let wakeTime = min(cancellationsHeldUntil, deadline)
            guard ContinuousClock.now < wakeTime else { return }
            try? await Task.sleep(until: wakeTime)
        }
    }

    /// Refreshes on behalf of something other than the user opening the app. Records and returns whether it worked.
    func backgroundRefresh(source: String) async -> Bool {
        await scheduleBackgroundRefresh()
        // Apply what's already on the phone first, in case iOS suspends the app during the wait.
        await syncAndRefresh()
        guard hasRequiredAccess else { return false }
        await waitForCalendarToSettle()
        guard !Task.isCancelled, await refresh() else { return false }
        let now = Date()
        lastBackgroundUpdate = now
        lastBackgroundSource = source
        UserDefaults.standard.set(now, forKey: Self.backgroundUpdateDateKey)
        UserDefaults.standard.set(source, forKey: Self.backgroundUpdateSourceKey)
        return true
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
            let succeeded = await backgroundRefresh(source: "Overnight")
            task.setTaskCompleted(success: succeeded)
        }
        task.expirationHandler = { work.cancel() }
    }

    func scheduleTestBuzz() async {
        actionErrorMessage = nil
        try? alarms.cancel(id: Self.testAlarmID)
        do {
            try await schedule(id: Self.testAlarmID, title: "MeetingBuzz test", at: Date(timeIntervalSinceNow: 10))
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    /// Only submits requests that aren't already pending, because resubmitting one pushes its earliest start back.
    func scheduleBackgroundRefresh() async {
        let pending = Set(await BGTaskScheduler.shared.pendingTaskRequests().map(\.identifier))

        if !pending.contains(Self.refreshTaskID) {
            let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(request)
        }

        if !pending.contains(Self.overnightTaskID) {
            let overnight = BGProcessingTaskRequest(identifier: Self.overnightTaskID)
            overnight.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
            overnight.requiresNetworkConnectivity = true
            try? BGTaskScheduler.shared.submit(overnight)
        }
    }

    private func syncAlarms() async -> Bool {
        errorMessage = nil
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        alarmAccess = alarms.authorizationState
        guard hasRequiredAccess else {
            reminders = []
            return false
        }

        let canCancel = ContinuousClock.now >= cancellationsHeldUntil
        let now = Date()
        let desired = ReminderPolicy.reminders(for: fetchEvents(from: now), now: now, leadTime: leadTime)

        var succeeded = true
        do {
            let changes = ReminderPolicy.alarmChanges(
                desired: desired,
                existing: try alarms.alarms.map {
                    ExistingAlarm(id: $0.id, isWaitingToFire: $0.state == .scheduled, fireDate: fireDate(of: $0))
                },
                canCancel: canCancel,
                keeping: [Self.testAlarmID]
            )
            for id in changes.cancel {
                try alarms.cancel(id: id)
            }
            for reminder in changes.schedule {
                try await schedule(id: reminder.id, title: reminder.alertTitle, at: reminder.fireDate)
            }
        } catch {
            errorMessage = error.localizedDescription
            succeeded = false
        }
        reminders = ReminderPolicy.listed(desired, now: now)
        return succeeded
    }

    private func fireDate(of alarm: Alarm) -> Date? {
        if case .fixed(let date) = alarm.schedule { date } else { nil }
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
