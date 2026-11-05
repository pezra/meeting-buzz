import AppIntents

struct RefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh MeetingBuzz"
    static let description = IntentDescription("Updates your buzzes from your calendar without opening the app.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await ReminderScheduler.shared.backgroundRefresh(source: "Shortcut") else {
            throw RefreshFailed()
        }
        return .result()
    }
}

struct RefreshFailed: LocalizedError {
    var errorDescription: String? {
        "MeetingBuzz couldn't update your buzzes. Open the app to try again."
    }
}

struct MeetingBuzzShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshIntent(),
            phrases: ["Refresh \(.applicationName)"],
            shortTitle: "Refresh",
            systemImageName: "arrow.clockwise"
        )
    }
}
