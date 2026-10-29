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

    /// `sync`: also asks the calendar accounts to fetch from their servers; what changed there arrives
    /// as EKEventStoreChanged and reloads again. Without it a long-running app can keep showing a
    /// meeting that was moved or cancelled hours ago.
    func reload(sync: Bool = false) {
        guard access else { return }
        if sync { store.refreshSourcesIfNecessary() }
        var seen = Set<String>()
        today = events()
            .filter(isMeeting)
            .sorted { $0.startDate < $1.startDate }
            // One meeting is on your calendar and on every colleague's calendar you've added: count it once.
            .filter { seen.insert("\($0.calendarItemExternalIdentifier ?? $0.eventIdentifier ?? "")|\($0.startDate.timeIntervalSince1970)").inserted }
            .map { Meeting(id: $0.eventIdentifier, title: $0.title ?? L("Среща", "Meeting"), start: $0.startDate, end: $0.endDate, url: link($0)) }
    }

    private func events() -> [EKEvent] {
        let day = Calendar.current.startOfDay(for: Date())
        return store.events(matching: store.predicateForEvents(withStart: day, end: day.addingTimeInterval(86400), calendars: nil))
    }

    /// A meeting of yours: not all-day, not *free*, with attendees, and you are one of them (or organise it)
    /// and haven't declined. Events on calendars shared with you, where you aren't invited, are someone
    /// else's meetings.
    private func isMeeting(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.availability != .free, let attendees = event.attendees, !attendees.isEmpty else { return false }
        if let me = attendees.first(where: \.isCurrentUser) { return me.participantStatus != .declined }
        return event.organizer?.isCurrentUser == true
    }

    /// Every event today with why it is or isn't counted, to check against the Calendar app
    /// (agentwidget://snapshot writes it to ~/.agent-widget/meetings.json).
    func diagnostics() -> [[String: String]] {
        events().map { event in
            let me = event.attendees?.first(where: \.isCurrentUser)
            return ["title": event.title ?? "", "start": event.startDate.description, "end": event.endDate.description,
                    "calendar": "\(event.calendar.title) (\(event.calendar.source.title))",
                    "attendees": "\(event.attendees?.count ?? 0)", "me": me.map { "\($0.participantStatus.rawValue)" } ?? "-",
                    "organizer": event.organizer?.isCurrentUser == true ? "me" : event.organizer?.name ?? "-",
                    "modified": event.lastModifiedDate?.description ?? "-", "shown": isMeeting(event) ? "yes" : "no"]
        }
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

    /// Today's meetings that haven't ended yet: the one you're in and the ones to come.
    func remaining(at now: Date) -> [Meeting] { today.filter { $0.end > now } }

    func upcoming(at now: Date) -> Meeting? {
        today.first { $0.start > now && $0.start.timeIntervalSince(now) <= Self.warnBefore }
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
