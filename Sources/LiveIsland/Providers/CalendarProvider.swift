import EventKit
import Foundation
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "calendar")

/// Today's upcoming events, from every calendar the user has in Calendar.
@MainActor
final class CalendarProvider {
    struct Event: Equatable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var color: CGColor?
        var location: String?

        static func == (lhs: Event, rhs: Event) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end && lhs.location == rhs.location
        }
    }

    var onUpdate: (([Event]) -> Void)?
    private(set) var events: [Event] = []
    private(set) var isAuthorized = false

    private let store = EKEventStore()
    private var refreshTimer: Timer?

    func start() {
        Task {
            do {
                isAuthorized = try await store.requestFullAccessToEvents()
            } catch {
                log.error("Calendar access failed: \(error.localizedDescription, privacy: .public)")
            }
            guard isAuthorized else { return }
            refresh()
            // The provider lives as long as the app, so these hold it strongly.
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { self.refresh() }
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
                MainActor.assumeIsolated { self.refresh() }
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
    }

    /// Timed events from now until midnight tomorrow; all-day events aren't "upcoming".
    func refresh() {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", start: $0.startDate,
                         end: $0.endDate, color: $0.calendar?.cgColor, location: $0.location) }
        guard next != events else { return }
        events = Array(next)
        onUpdate?(events)
    }
}
