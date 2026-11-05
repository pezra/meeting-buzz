import SwiftUI

@main
struct MeetingBuzzApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let scheduler = ReminderScheduler.shared

    init() {
        ReminderScheduler.registerOvernightRefresh()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(scheduler: scheduler)
                .task {
                    await scheduler.requestPermissions()
                    await scheduler.syncAndRefresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await scheduler.syncAndRefresh() }
            case .background: Task { await scheduler.scheduleBackgroundRefresh() }
            default: break
            }
        }
        .backgroundTask(.appRefresh(ReminderScheduler.refreshTaskID)) {
            _ = await scheduler.backgroundRefresh(source: "Background refresh")
        }
    }
}
