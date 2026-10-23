import EventKit
import Foundation

/// Today's meetings from the Mac's calendars (the work Google account must be added in
/// System Settings → Internet Accounts for them to show up here).
@MainActor
final class Meetings: ObservableObject {
    static let warnBefore: TimeInterval = 10 * 60

    @Published private(set) var today: [Meeting] = []
    @Published private(set) var access = true

    struct Meeting: Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var url: URL?
    }

    private let store = EKEventStore()

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.access = granted
                self?.reload()
            }
        }
    }

    func reload() {
        guard access else { return }
        let day = Calendar.current.startOfDay(for: Date())
        let predicate = store.predicateForEvents(withStart: day, end: day.addingTimeInterval(86400), calendars: nil)
        today = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free && !declined($0) && ($0.attendees?.count ?? 0) > 0 }
            .sorted { $0.startDate < $1.startDate }
            .map { Meeting(id: $0.eventIdentifier, title: $0.title ?? "Среща", start: $0.startDate, end: $0.endDate, url: link($0)) }
    }

    /// Demo meetings: [{"title": "Planning", "startsIn": 4, "minutes": 30}], minutes relative to now.
    func useDemo(_ url: URL) {
        struct Item: Decodable { var title: String; var startsIn: Double; var minutes: Double }
        let items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: url))) ?? []
        access = true
        today = items.enumerated().map { i, item in
            let start = Date().addingTimeInterval(item.startsIn * 60)
            return Meeting(id: "demo-\(i)", title: item.title, start: start, end: start.addingTimeInterval(item.minutes * 60), url: nil)
        }
    }

    func current(at now: Date) -> Meeting? { today.first { $0.start <= now && now < $0.end } }

    func upcoming(at now: Date) -> Meeting? {
        today.first { $0.start > now && $0.start.timeIntervalSince(now) <= Self.warnBefore }
    }

    private func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// The video call link: the event URL, or the first Meet/Zoom/Teams link in the notes or location.
    private func link(_ event: EKEvent) -> URL? {
        if let url = event.url { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://(meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com)/\S+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}
