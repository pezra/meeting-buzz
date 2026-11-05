import AlarmKit
import EventKit
import SwiftUI

struct ContentView: View {
    let scheduler: ReminderScheduler
    @Environment(\.openURL) private var openURL
    @State private var testScheduled = false

    var body: some View {
        NavigationStack {
            List {
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                        }
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                }

                Section {
                    Button("Test buzz in 10 seconds") {
                        testScheduled = true
                        Task { await scheduler.scheduleTestBuzz() }
                    }
                } footer: {
                    if testScheduled {
                        Text("Lock your phone now. It should keep buzzing until you dismiss it.")
                    }
                }

                Section {
                    if scheduler.reminders.isEmpty {
                        Text("No events with other people in the next \(ReminderPolicy.lookaheadDays) days.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(scheduler.reminders) { reminder in
                        VStack(alignment: .leading) {
                            Text(reminder.title)
                            Text(reminder.eventStart, format: .dateTime.weekday().month().day().hour().minute())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Upcoming buzzes")
                } footer: {
                    if let date = scheduler.lastBackgroundUpdate, let source = scheduler.lastBackgroundSource {
                        TimelineView(.everyMinute) { _ in
                            Text("Last background update: \(date.formatted(.relative(presentation: .numeric))) (\(source))")
                        }
                    } else {
                        Text("Last background update: none yet")
                    }
                }
            }
            .navigationTitle("MeetingBuzz")
            .refreshable { await scheduler.syncAndRefresh() }
        }
    }

    private var warnings: [String] {
        var result: [String] = []
        if scheduler.calendarAccess != .fullAccess && scheduler.calendarAccess != .notDetermined {
            result.append("Calendar access is off, so MeetingBuzz can't see your events.")
        }
        if scheduler.alarmAccess == .denied {
            result.append("Alarm access is off, so MeetingBuzz can't vibrate.")
        }
        if let error = scheduler.errorMessage {
            result.append(error)
        }
        if let error = scheduler.actionErrorMessage, error != scheduler.errorMessage {
            result.append(error)
        }
        return result
    }
}
