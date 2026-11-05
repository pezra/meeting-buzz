import EventKit
import SwiftUI

@main
struct MeetingBuzzApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scheduler = ReminderScheduler.shared

    init() {
        ReminderScheduler.registerOvernightRefresh()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(scheduler: scheduler)
                .task {
                    await scheduler.requestPermissions()
                    scheduler.requestCalendarSync()
                    await scheduler.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    Task { await scheduler.refresh() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                scheduler.requestCalendarSync()
                Task { await scheduler.refresh() }
            case .background: scheduler.scheduleBackgroundRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh(ReminderScheduler.refreshTaskID)) {
            await ReminderScheduler.shared.backgroundRefresh(source: "Background refresh")
        }
    }
}
