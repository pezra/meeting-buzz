import EventKit
import SwiftUI

@main
struct MeetingBuzzApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scheduler = ReminderScheduler()

    var body: some Scene {
        WindowGroup {
            ContentView(scheduler: scheduler)
                .task {
                    await scheduler.requestPermissions()
                    await scheduler.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    Task { await scheduler.refresh() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await scheduler.refresh() }
            case .background: scheduler.scheduleBackgroundRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh(ReminderScheduler.refreshTaskID)) {
            await scheduler.scheduleBackgroundRefresh()
            await scheduler.refresh()
        }
    }
}
