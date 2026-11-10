import AppKit
import SwiftUI

/// Explorer: a walk over the panel, one bubble at a time next to the part it explains, with ‹ › to move
/// between parts and ✕ to stop. Started from the header's ?. Parts the panel isn't
/// showing right now (no Slack, no tasks) are skipped.
@MainActor
final class Tour: ObservableObject {
    static let shared = Tour()

    /// The part being explained; nil while the tour is off.
    @Published private(set) var current: String?
    /// Where each part is on the panel now, in the panel's coordinates; reported by the parts themselves.
    var frames: [String: CGRect] = [:] {
        didSet { if current != nil { place() } }
    }
    weak var panel: NSWindow?
    /// Where the tour was, so it can carry on from there when that part leaves the panel (Slack read, task done).
    private var lastIndex = 0

    private let window: NSPanel
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    struct Stop {
        var id: String
        var title: String
        var text: String
    }

    static var stops: [Stop] {
        [
            Stop(id: "header", title: "TheWatcher",
                 text: L("Твоите AI агенти, PR-и, тикети, Slack и срещи на едно място. Двоен клик тук обновява всичко веднага.",
                         "Your AI agents, PRs, tickets, Slack and meetings in one place. Double-click here to refresh everything now.")),
            Stop(id: "pin", title: L("Закачване", "Pin"),
                 text: L("Закачен, панелът стои над всички прозорци. Откачен, седи на десктопа под тях.",
                         "Pinned, the panel floats above every window. Unpinned, it sits on the desktop under them.")),
            Stop(id: "help", title: "Explorer",
                 text: L("Тази обиколка. Натисни ? когато искаш да видиш какво е всяко нещо.",
                         "This tour. Click ? whenever you want to see what each part is.")),
            Stop(id: "close", title: L("Затваряне", "Close"),
                 text: L("Скрива панела и спира обновяването. Отваря се пак от бинокъла в менюбара.",
                         "Hides the panel and stops updates. Open it again from the binoculars in the menu bar.")),
            Stop(id: "status", title: L("Какво прави агентът", "What the agent is doing"),
                 text: L("Оранжева ръка: агент чака твоя отговор (тези са най-отгоре). Сини искри: работи. Зелена отметка: готов. Луна: няма агент, но PR или тикет още е отворен.",
                         "Orange hand: an agent waits for your answer (these come first). Blue sparkles: working. Green check: done. Moon: no agent, but a PR or ticket is still open.")),
            Stop(id: "task", title: L("Задача", "Task"),
                 text: L("Един ред на задача: сесии, PR-и и тикети с един и същ Jira ключ са заедно. Отдолу: ключът и какво те пита агентът или кой е PR-ът. Клик на реда отваря Claude сесията.",
                         "One row per task: sessions, PRs and tickets with the same Jira key are joined. Below: the key and what the agent asks you, or which PR it is. Click the row to open the Claude session.")),
            Stop(id: "stage", title: L("Докъде е стигнала", "How far it got"),
                 text: L("код → pushed → AI review → CI → staging → prod. Посочи точка от линията, за да видиш етапа.",
                         "code → pushed → AI review → CI → staging → prod. Hover a point of the bar to see that stage.")),
            Stop(id: "github", title: L("PR-ът", "The PR"),
                 text: L("Сиво draft, светлосиньо чака AI review, оранжево искат се промени, жълто CI върви, червено CI пада или конфликт, зелено готов за merge, лилаво merged, тюркоаз на prod. Клик отваря PR-а.",
                         "Grey draft, light blue waiting for AI review, orange changes requested, yellow CI running, red CI failing or a conflict, green ready to merge, violet merged, teal on prod. Click to open the PR.")),
            Stop(id: "slack", title: "Slack",
                 text: L("Непрочетени лични съобщения и споменавания. Изчезват, щом ги прочетеш. Клик отваря Slack.",
                         "Unread direct messages and mentions. They go away once read. Click to open Slack.")),
            Stop(id: "e2e", title: "e2e",
                 text: L("Последният run на e2e проверката за уеб: зелено мина, червено падна; часовникът мига, докато върви нов. Клик отваря run-а.",
                         "The last run of the web e2e gate: green passed, red failed; the clock blinks while one runs. Click to open the run.")),
            Stop(id: "prod", title: L("Уеб на prod", "Web on prod"),
                 text: L("Преди колко време последната уеб версия стигна prod; часовникът мига, докато се качва следващата. Посочи за PR-ите в нея.",
                         "How long ago the last web release reached production; the clock blinks while the next one goes out. Hover for its PRs.")),
            Stop(id: "mobile", title: L("Мобилното приложение", "Mobile app"),
                 text: L("От колко време последната мобилна версия е в магазините. Телефонът е зелен или червен според последния мобилен e2e run; часовникът мига, докато се пуска нова версия.",
                         "How long the newest mobile version has been in the stores. The phone is green or red by the last mobile e2e run; the clock blinks while a new version is going out.")),
            Stop(id: "prs", title: L("PR-и", "PRs"),
                 text: L("Отворените ти PR-и / merged тази седмица / merged този месец. Клик показва отворените ти PR-и.",
                         "Your open PRs / merged this week / merged this month. Click for your open PRs.")),
            Stop(id: "jira", title: "Jira",
                 text: L("Отворените ти тикети / завършени тази седмица / завършени този месец.", "Your open tickets / done this week / done this month.")),
            Stop(id: "limit", title: L("Лимит на Claude", "Claude limit"),
                 text: L("Колко от 5-часовия ти лимит в Claude е изразходван: зелено, оранжево над 70%, червено над 90%. Сиво значи, че данните са стари.",
                         "How much of your 5-hour Claude limit is used: green, orange past 70%, red past 90%. Grey means the reading is old.")),
            Stop(id: "calendar", title: L("Срещи", "Meetings"),
                 text: L("Колко срещи ти остават днес. Оранжево 10 минути преди среща, червено по време на нея; клик влиза в разговора.",
                         "How many meetings you have left today. Orange 10 minutes before one, red during it; click to join the call.")),
            Stop(id: "week", title: L("Седмицата", "The week"),
                 text: L("Пълни се от понеделник 9:00 до петък 18:00. Посочи я за деня.",
                         "Fills up from Monday 9:00 to Friday 18:00. Hover it for the day.")),
        ]
    }

    private init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar  // above the panel even when it is pinned
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = host
    }

    /// The parts on the panel right now, in tour order.
    private var shown: [Stop] { Self.stops.filter { frames[$0.id] != nil } }

    func start(at index: Int = 0) {
        let stops = shown
        guard !stops.isEmpty else { return }
        Tooltip.shared.hide()
        current = stops[max(0, min(index, stops.count - 1))].id
        place()
    }

    func stop() {
        current = nil
        window.orderOut(nil)
    }

    /// One part forward or back; past the last one the tour ends.
    func step(_ by: Int) {
        let stops = shown
        guard let i = stops.firstIndex(where: { $0.id == current }) else { return stop() }
        let next = i + by
        if next >= stops.count { return stop() }
        current = stops[max(0, next)].id
        place()
    }

    /// Puts the bubble beside the panel, level with the part: right of the panel if it fits on the
    /// screen, else left of it.
    func place() {
        let stops = shown
        guard let panel, current != nil else { return window.orderOut(nil) }
        if !stops.contains(where: { $0.id == current }) {  // that part is gone from the panel: the next one still there
            guard !stops.isEmpty else { return stop() }
            current = stops[min(lastIndex, stops.count - 1)].id
        }
        guard let id = current, let index = stops.firstIndex(where: { $0.id == id }), let frame = frames[id] else { return }
        lastIndex = index
        let part = NSRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let gap: CGFloat = 10
        var size = bubbleSize(stops[index], index: index, count: stops.count, arrow: .leading)
        let right = panel.frame.maxX + gap + size.width <= screen.maxX
        let edge: HorizontalEdge = right ? .leading : .trailing
        size = bubbleSize(stops[index], index: index, count: stops.count, arrow: edge)
        let x = right ? panel.frame.maxX + gap : panel.frame.minX - gap - size.width
        let y = min(max(part.midY - size.height / 2, screen.minY + 4), screen.maxY - size.height - 4)
        // Level with the part, but always on the bubble, also when the bubble was pushed back onto the screen.
        let arrowY = min(max(size.height - (part.midY - y), 17), size.height - 17)
        host.rootView = AnyView(TourBubble(stop: stops[index], index: index, count: stops.count, arrow: edge, arrowY: arrowY))
        window.setFrame(NSRect(x: max(screen.minX + 4, x), y: y, width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
    }

    private func bubbleSize(_ stop: Stop, index: Int, count: Int, arrow: HorizontalEdge) -> CGSize {
        host.rootView = AnyView(TourBubble(stop: stop, index: index, count: count, arrow: arrow, arrowY: 0))
        return host.fittingSize
    }

    /// Writes the bubble as a PNG (demo snapshots).
    func snapshot(to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// One explanation: title and ✕, the text, then which part of how many and ‹ ›. A small arrow on the
/// side that faces the panel points at the part.
struct TourBubble: View {
    var stop: Tour.Stop
    var index: Int
    var count: Int
    var arrow: HorizontalEdge
    var arrowY: CGFloat
    static let fill = Color(red: 0.09, green: 0.11, blue: 0.16)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(stop.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 12)
                TourButton(label: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)), round: true) { Tour.shared.stop() }
                    .hoverTip(L("Спри обиколката", "Stop the tour"))
            }
            Text(stop.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("\(index + 1) / \(count)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if index > 0 {
                    TourButton(label: Text(L("‹ Назад", "‹ Back")).font(.system(size: 11, weight: .medium))) { Tour.shared.step(-1) }
                }
                TourButton(label: Text(index + 1 < count ? L("Напред ›", "Next ›") : L("Готово", "Done")).font(.system(size: 11, weight: .semibold)),
                           accent: true) { Tour.shared.step(1) }
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(Self.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .overlay(alignment: arrow == .leading ? .topLeading : .topTrailing) {
            Arrow(pointsLeft: arrow == .leading)
                .fill(Self.fill)
                .frame(width: 7, height: 14)
                .offset(x: arrow == .leading ? -7 : 7, y: arrowY - 7)
        }
        .padding(arrow == .leading ? .leading : .trailing, 7)
        .fixedSize()
    }

    struct Arrow: Shape {
        var pointsLeft: Bool

        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: pointsLeft ? rect.maxX : rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: pointsLeft ? rect.minX : rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: pointsLeft ? rect.maxX : rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

/// A bubble button: a light pill on hover, the accent colour for the main one.
struct TourButton<Label: View>: View {
    var label: Label
    var accent = false
    var round = false
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        label
            .foregroundStyle(accent ? Color.black.opacity(0.85) : .white.opacity(0.8))
            .padding(.horizontal, round ? 0 : 9)
            .frame(minWidth: round ? 18 : nil, minHeight: round ? 18 : 22)
            .background(accent ? Palette.accent.opacity(hovered ? 1 : 0.9) : Color.white.opacity(hovered ? 0.14 : 0.07),
                        in: Capsule())
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
    }
}

/// Where each tour part is on the panel.
struct TourFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks a part of the panel the tour explains: reports where it is, and outlines it while it's explained.
    /// nil: not a tour part (every task row but the first).
    @ViewBuilder
    func tourStop(_ id: String?, inset: CGFloat = -3) -> some View {
        if let id { modifier(TourStop(id: id, inset: inset)) } else { self }
    }
}

struct TourStop: ViewModifier {
    var id: String
    var inset: CGFloat
    @ObservedObject private var tour = Tour.shared

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                Color.clear.preference(key: TourFrames.self, value: [id: geo.frame(in: .named(Tour.space))])
            })
            .overlay {
                if tour.current == id {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 1.5)
                        .padding(inset)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension Tour {
    /// The panel's coordinate space, in which the parts report their frames.
    static let space = "panel"
}
