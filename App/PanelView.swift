import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    static let pinnedKey = "pinnedAboveWindows"

    @Published var snapshot: Snapshot?
    /// Pinned: the panel floats above every window. Unpinned: it sits on the desktop, under them.
    @Published var pinned = !Demo.isOn && UserDefaults.standard.bool(forKey: pinnedKey) {
        didSet { UserDefaults.standard.set(pinned, forKey: Self.pinnedKey) }
    }
    /// Dragged on the panel's right edge, so longer titles fit.
    @Published var width = Demo.isOn ? 360 : CGFloat(max(360, UserDefaults.standard.object(forKey: widthKey) as? Double ?? 360)) {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }
    static let widthKey = "panelWidth"
    /// Closed with the panel's X; opened again from the menu bar ticket.
    @Published var hidden = !Demo.isOn && UserDefaults.standard.bool(forKey: hiddenKey) {
        didSet { UserDefaults.standard.set(hidden, forKey: Self.hiddenKey) }
    }
    static let hiddenKey = "panelHidden"
    /// Closed (not just hidden): no updates until it's opened again.
    @Published var paused = !Demo.isOn && UserDefaults.standard.bool(forKey: pausedKey) {
        didSet { UserDefaults.standard.set(paused, forKey: Self.pausedKey) }
    }
    static let pausedKey = "updatesPaused"
}

// MARK: - Palette

enum Palette {
    static let track = Color.white.opacity(0.12)
    static let fill = Color.white.opacity(0.45)
    /// Outer glass: 80% dark over the blurred wallpaper, so 20% of what's behind shows through.
    static let outerLayer = Color(red: 0.03, green: 0.05, blue: 0.10).opacity(0.8)
    /// The task layer on top of it: 90% dark, 10% see-through.
    static let tasksLayer = Color(red: 0.03, green: 0.05, blue: 0.10).opacity(0.9)

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static func agent(_ state: String) -> (color: Color, light: Color, label: String) {
        switch state {
        case "working": (hex(0x1D4ED8), hex(0x5B8DEF), "Агентът работи")
        case "waiting": (hex(0xC2410C), hex(0xF59E5B), "Агентът чака теб")
        case "done": (hex(0x15803D), hex(0x4ADE80), "Агентът е готов")
        default: (hex(0x2F3542), hex(0x5B6475), "Няма агент по задачата")
        }
    }

    /// The brand accent (config.json → brand.accent): header mark, pinned pin, week bar.
    static var accent = hex(0x3DDC84)

    static func hex(_ string: String?) -> Color? {
        guard let string, let value = UInt32(string.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        return hex(value)
    }

    static func jira(_ state: String) -> (color: Color, meaning: String) {
        switch state {
        case "progress": (hex(0x3B82F6), "синьо = в работа")
        case "review": (hex(0xA78BFA), "лилаво = чака review")
        case "staging": (hex(0x4ADE80), "зелено = на staging")
        case "done": (hex(0x2DD4BF), "тюркоаз = готово")
        case "blocked": (hex(0xF87171), "червено = блокиран")
        case "unknown": (hex(0x3A3A3A), "тъмно = няма връзка с Jira")
        default: (hex(0x6B6B6B), "сиво = не е започнат")
        }
    }

    static func github(_ state: String) -> (color: Color, meaning: String) {
        switch state {
        case "draft": (hex(0x6B6B6B), "сиво = draft")
        case "review": (hex(0x93C5FD), "светлосиньо = чака AI review")
        case "changes": (hex(0xFB923C), "оранжево = AI review иска промени")
        case "ci": (hex(0xFBBF24), "жълто = CI върви")
        case "fail": (hex(0xF87171), "червено = CI пада или конфликт")
        case "ready": (hex(0x4ADE80), "зелено = approved и зелен CI, готов за merge")
        case "merged": (hex(0xA78BFA), "лилаво = merged, на staging")
        case "prod": (hex(0x2DD4BF), "тюркоаз = на prod")
        default: (hex(0x3A3A3A), "тъмно = няма PR")
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var meetings: Meetings
    var open: (String) -> Void
    var resized: (CGSize) -> Void
    var refresh: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Header(brand: store.snapshot?.brand, pinned: $store.pinned, close: { store.paused = true; store.hidden = true },
                   refresh: refresh)
            if let snapshot = store.snapshot {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Separator() }
                        TaskRow(task: task, open: open)
                    }
                    if snapshot.tasks.isEmpty {
                        placeholder("Няма активни задачи")
                    }
                }
                .padding(.horizontal, 6)
                // The lift is on the layer's shape only: a shadow on the list would outline every row.
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.tasksLayer)
                    .shadow(color: .white.opacity(0.06), radius: 6)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))  // row tints reach the layer's edges
                // Same hairline as the outer glass, brighter at the top, plus a soft lift so the layer stands out.
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.08)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                )
                if let slack = snapshot.slack, !slack.isEmpty {
                    SlackList(items: slack, open: open)
                    Separator().padding(.horizontal, 6)
                }
                Footer(stats: snapshot.stats, errors: snapshot.errors, meetings: meetings, open: open)
            } else {
                placeholder("Събирам данните…")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .frame(width: store.width)
        .background(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                Glass()
                EdgeGlow()
            }
        }
        .overlay(alignment: .bottom) { WeekLine() }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .overlay(alignment: .trailing) { ResizeEdge(width: $store.width) }
        .gesture(WindowDragGesture())  // drag the panel from anywhere; a click still reaches rows and icons
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: resized)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

/// Top strip: the brand mark and name on the left, the Mac user's full name and the pin on the right.
/// The mark is ~/.agent-widget/brand.svg when there is one.
struct Header: View {
    var brand: Snapshot.Brand?
    @Binding var pinned: Bool
    var close: () -> Void
    var refresh: () -> Void
    @State private var pinHovered = false
    @State private var closeHovered = false

    var body: some View {
        // One 22 pt row, everything centred on it. The P lines up with the status squares below
        // and the pin with the GitHub icons.
        HStack(spacing: 0) {
          // Everything but the pin and ✕: click to collect fresh data now.
          HStack(spacing: 0) {
            Group {
                if let mark = Self.mark {
                    Image(nsImage: mark).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "sparkles").resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 11, height: 15)
            .foregroundStyle(Palette.accent)
            Text(brand?.name ?? "Agent Widget")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 7)
            Spacer(minLength: 8)
            (Text(Image(systemName: "person.fill")).font(.system(size: 10)).baselineOffset(1.5) + Text(" " + (Demo.isOn ? "Jamie Rivera" : NSFullUserName())).font(.system(size: 12)))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
          }
          .contentShape(Rectangle())
          .hoverTip("Клик → обнови данните сега", "сесии, PR-и, Slack и срещи")
          .onTapGesture {
              refresh()
              Tooltip.shared.show(title: "Обновявам…")
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Tooltip.shared.hide() }
          }
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(45))
                .foregroundStyle(pinned ? Palette.accent : .white.opacity(0.7))
                .frame(width: 18, height: 22)
                .background(Circle().fill(Color.white.opacity(pinHovered ? 0.08 : 0)))
                .contentShape(Circle())
                .padding(.leading, 10)  // the two buttons sit together, apart from the name
                .onHover { inside in
                    pinHovered = inside
                    if inside {
                        Tooltip.shared.show(title: pinned ? "Над всички прозорци" : "На десктопа, под прозорците",
                                            detail: pinned ? "клик → върни го на десктопа" : "клик → закачи го над всичко")
                    } else {
                        Tooltip.shared.hide()
                    }
                }
                .onTapGesture {
                    pinned.toggle()
                    Tooltip.shared.hide()
                }
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, height: 22)
                .background(Circle().fill(Color.white.opacity(closeHovered ? 0.08 : 0)))
                .contentShape(Circle())
                .onHover { inside in
                    closeHovered = inside
                    if inside {
                        Tooltip.shared.show(title: "Затвори панела", detail: "спира и обновяването; отваря се от билетчето горе")
                    } else {
                        Tooltip.shared.hide()
                    }
                }
                .onTapGesture {
                    Tooltip.shared.hide()
                    close()
                }
        }
        .frame(height: 22)
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 7, trailing: 11))
    }

    static let mark: NSImage? = {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agent-widget/brand.svg")
        guard !Demo.isOn, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()
}

/// Still glow from the top-left corner over 80% of the panel's width and 40% of its height:
/// blue in the corner, violet to the right, teal and green below, fading out before its edges.
struct EdgeGlow: View {
    static let patches: [(color: UInt32, opacity: Double, center: UnitPoint, radius: CGFloat)] = [
        (0x3B82F6, 0.75, .topLeading, 0.65),
        (0x8B5CF6, 0.55, UnitPoint(x: 0.55, y: 0.12), 0.5),
        (0x14B8A6, 0.50, UnitPoint(x: 0.12, y: 0.72), 0.5),
        (0x22C55E, 0.35, UnitPoint(x: 0.4, y: 0.55), 0.38),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.patches.indices, id: \.self) { i in
                    let patch = Self.patches[i]
                    EllipticalGradient(colors: [Palette.hex(patch.color).opacity(patch.opacity), .clear],
                                       center: patch.center, endRadiusFraction: patch.radius)
                }
            }
            .frame(width: geo.size.width * 0.8, height: geo.size.height * 0.4)
            .mask(EllipticalGradient(stops: [.init(color: .black, location: 0.35), .init(color: .clear, location: 1)],
                                     center: .topLeading, endRadiusFraction: 1))
        }
        .allowsHitTesting(false)
    }
}

/// The panel's right edge: drag it to make the panel wider or narrower.
struct ResizeEdge: View {
    static let range: ClosedRange<CGFloat> = 360...720
    @Binding var width: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let from = start ?? width
                    start = from
                    width = min(Self.range.upperBound, max(Self.range.lowerBound, from + drag.translation.width))
                }
                .onEnded { _ in start = nil })
    }
}

struct Separator: View {
    var body: some View {
        Color.white.opacity(0.08).frame(height: 0.5)
    }
}

/// Behind-window blur of the wallpaper with a light white tint.
struct Glass: View {
    var body: some View {
        ZStack {
            if !Demo.isOn { VisualEffect() }  // demo snapshots get the blur from the README compositor
            Palette.outerLayer
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        // Mostly blur, little tint of its own: the see-through amount is set by Palette.outerLayer.
        let view = NSVisualEffectView()
        view.appearance = NSAppearance(named: .vibrantDark)
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Week line

struct WeekLine: View {
    static let days = ["Понеделник", "Вторник", "Сряда", "Четвъртък", "Петък"]
    static let workday = (start: 9.0, end: 18.0)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let week = Self.progress(context.date)
            ZStack(alignment: .leading) {
                Palette.track
                GeometryReader { geo in Palette.accent.frame(width: geo.size.width * week.fraction) }
            }
            .frame(height: 2)
            .frame(height: 8, alignment: .bottom)
            .hoverTip { x, width in
                let day = min(4, Int(x / width * 5))
                let state: String
                if week.weekday > 4 || day < week.weekday {
                    state = "минал"
                } else if day > week.weekday {
                    state = "предстои"
                } else {
                    state = "\(context.date.formatted(date: .omitted, time: .shortened)) · \(Int(week.today * 100))% от деня"
                }
                return ("\(Self.days[day]) · \(state)", "седмицата: \(Int(week.fraction * 100))%")
            }
        }
    }

    static func progress(_ date: Date) -> (fraction: Double, today: Double, weekday: Int) {
        let calendar = Calendar.current
        let weekday = (calendar.component(.weekday, from: date) + 5) % 7  // Monday = 0
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        let today = min(1, max(0, (hour - workday.start) / (workday.end - workday.start)))
        let fraction = weekday > 4 ? 1 : (Double(weekday) + today) / 5
        return (fraction, today, weekday)
    }
}

// MARK: - Task row

struct TaskRow: View {
    var task: TaskItem
    var open: (String) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            StatusSquare(task: task)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 4) {
                    if let key = task.key {
                        Text(key)
                        Text("·")
                    }
                    Text(task.note.isEmpty && task.key == nil ? "без тикет" : task.note).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.hex(0x8FA3BF))
                StageLine(task: task).frame(width: 150).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                IconButton(name: "github", color: Palette.github(task.github?.state ?? "none").color,
                           tip: ("GitHub: \(githubTitle)", Palette.github(task.github?.state ?? "none").meaning)) {
                    task.github.map { open($0.url) }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(LinearGradient(stops: [.init(color: Palette.agent(task.agent).color.opacity(0.22), location: 0),
                                           .init(color: Palette.agent(task.agent).color.opacity(0.06), location: 0.35),
                                           .init(color: .clear, location: 0.6)],
                                   startPoint: .leading, endPoint: .trailing))
        .background(hovered ? Color.white.opacity(0.04) : .clear)
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { open(task.url) }
    }

    private var githubTitle: String {
        guard let github = task.github else { return "няма PR" }
        return github.count > 1 ? "\(github.label) (+\(github.count - 1) PR-а)" : github.label
    }
}

struct StatusSquare: View {
    var task: TaskItem

    var body: some View {
        let look = Palette.agent(task.agent)
        Group {
            switch task.agent {
            case "waiting": WavingHand()
            case "working": Spinner()
            case "done": Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
            default: Image(systemName: "moon.fill").font(.system(size: 13))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(LinearGradient(colors: [look.light, look.color], startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: look.color.opacity(0.45), radius: 5, y: 2)
        .hoverTip(look.label, task.agent == "waiting" ? task.note : nil)
    }
}

/// Waves left and right three times, then rests.
struct WavingHand: View {
    static let keys: [(t: Double, angle: Double)] = [(0, 0), (0.07, -18), (0.14, 18), (0.21, -18), (0.28, 18),
                                                     (0.35, -14), (0.42, 14), (0.49, -6), (0.56, 0), (1, 0)]

    var body: some View {
        TimelineView(.animation) { context in
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14))
                .rotationEffect(.degrees(Self.angle(context.date)), anchor: UnitPoint(x: 0.5, y: 0.9))
        }
    }

    static func angle(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
        guard let i = keys.firstIndex(where: { $0.t > t }), i > 0 else { return 0 }
        let a = keys[i - 1], b = keys[i]
        let k = (t - a.t) / (b.t - a.t)
        return a.angle + (b.angle - a.angle) * (0.5 - cos(k * .pi) / 2)
    }
}

/// "An AI agent is working": the sparkles symbol, its three stars lighting up one after another.
struct Spinner: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 15, weight: .semibold))
            .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
    }
}

struct BrandIcon: View {
    var name: String
    var color: Color
    var size = CGSize(width: 16, height: 16)

    var body: some View {
        Image(nsImage: Self.image(name))
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
            .frame(width: size.width, height: size.height)
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
    }

    static func image(_ name: String) -> NSImage {
        let image = Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// A row's Jira / GitHub icon: its own light circle on hover (like the row hover), a tooltip, and a click of its own.
struct IconButton: View {
    var name: String
    var color: Color
    var tip: (String, String?)
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        BrandIcon(name: name, color: color)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(Circle())
            .onHover { inside in
                hovered = inside
                if inside {
                    Tooltip.shared.show(title: tip.0, detail: tip.1)
                } else {
                    Tooltip.shared.hide()
                }
            }
            .onTapGesture(perform: action)
    }
}

/// Thin rounded bar: grey track, lighter grey up to `fraction`.
struct ProgressLine: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.fill).frame(width: max(3, geo.size.width * fraction))
            }
        }
        .frame(height: 2)
    }
}

/// The task's progress through code → pushed → AI review → CI → staging → prod.
struct StageLine: View {
    var task: TaskItem

    var body: some View {
        ProgressLine(fraction: min(1, Double(task.stage + 1) / Double(Stage.names.count)))
            .padding(.vertical, 3)
            .hoverTip { x, width in
                let index = min(Stage.names.count - 1, max(0, Int(x / width * Double(Stage.names.count))))
                let current = task.stage < Stage.names.count ? Stage.names[task.stage] : "на prod"
                return ("\(index + 1). \(Stage.names[index]) · \(Stage.describe(index: index, stage: task.stage, state: task.stageState))",
                        "сега: \(current)")
            }
    }
}

// MARK: - Slack

/// Unread DMs and mentions, straight on the glass (no layer of their own), one text line each.
struct SlackList: View {
    var items: [SlackItem]
    var open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                SlackRow(item: item, open: open)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
    }
}

struct SlackRow: View {
    var item: SlackItem
    var open: (String) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            (Text(item.channel.map { "\(item.name) · #\($0)" } ?? item.name).fontWeight(.semibold).foregroundColor(.white)
                + Text(" · \(item.text)").foregroundColor(Palette.hex(0x8FA3BF)))
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(item.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.hex(0xF6B3C8))
                .frame(minWidth: 14, minHeight: 14)
                .padding(.horizontal, 4)
                .background(Palette.hex(0xE01E5A).opacity(0.32), in: Capsule())
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(Color.white.opacity(hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .hoverTip(item.channel == nil ? "Лично съобщение" : "Споменаване в #\(item.channel!)", "клик → Slack")
        .onTapGesture { open(item.url) }
    }
}

// MARK: - Footer

struct Footer: View {
    var stats: Snapshot.Stats
    var errors: [String: String]
    @ObservedObject var meetings: Meetings
    var open: (String) -> Void
    @State private var e2eHovered = false
    @State private var calendarHovered = false
    static let calendarWeb = "https://calendar.google.com/calendar/r/day"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
          VStack(spacing: 0) {
            HStack(spacing: 14) {
                if stats.e2e != nil || errors["e2e"] != nil { e2e }
                counter(icon: "arrow.triangle.pull", counts: stats.prs, title: "Твоите PR-и", error: errors["prCounts"])
                Spacer(minLength: 0)
                calendar(context.date)
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.85))
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 6))
          }
        }
    }

    private var e2e: some View {
        let state = stats.e2e
        let color: Color = state == nil ? .gray : state!.ok ? Palette.hex(0x4ADE80) : Palette.hex(0xF87171)
        return HStack(spacing: 3) {
            Text("e2e").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            if (state?.running ?? 0) > 0 {
                TimelineView(.animation) { context in
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.hex(0x60A5FA))
                        .opacity(0.6 + 0.4 * cos(context.date.timeIntervalSinceReferenceDate * .pi / 0.6))
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.white.opacity(e2eHovered ? 0.08 : 0), in: Capsule())
        .padding(.horizontal, -5)
        .onHover { e2eHovered = $0 }
        .hoverTip(e2eTitle, e2eDetail)
        .onTapGesture { state?.url.map(open) }
    }

    private var e2eTitle: String {
        guard let state = stats.e2e else { return "e2e: няма данни" }
        return state.ok ? "e2e: последният run мина" : "e2e: последният run падна"
    }

    private var e2eDetail: String? {
        guard let state = stats.e2e else { return errors["e2e"] }
        var lines: [String] = []
        if let recent = state.recent { lines.append("\(state.passed ?? 0) от последните \(recent) минаха") }
        if state.running > 0 { lines.append("\(state.running) вървят в момента") }
        lines.append(state.running > 0 ? "клик → текущият run" : "клик → последният run")
        return lines.joined(separator: "\n")
    }

    private func counter(icon: String, counts: Snapshot.Counts?, title: String, error: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            if let counts {
                Text("\(counts.week)") + Text("/\(counts.month)").foregroundColor(.white.opacity(0.45))
            } else {
                Text("–")
            }
        }
        .hoverTip(title, counts.map { "\($0.week) тази седмица · \($0.month) този месец" } ?? error)
    }

    /// Today's meeting count; turns into an orange "3 · 4 мин" pill before a meeting and a red one during it.
    private func calendar(_ now: Date) -> some View {
        let count = Text(meetings.access ? "\(meetings.today.count)" : "–")
        let schedule = meetings.today.map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title)" }.joined(separator: "\n")
        return Group {
            if let meeting = meetings.current(at: now) {
                let left = Int(meeting.end.timeIntervalSince(now) / 60)
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    count
                    Text("·")
                    TimelineView(.animation) { context in
                        Circle().fill(Palette.hex(0xF87171)).frame(width: 6, height: 6)
                            .opacity(0.55 + 0.45 * cos(context.date.timeIntervalSinceReferenceDate * .pi / 0.8))
                    }
                    .frame(width: 6, height: 6)
                    Text("в среща")
                }
                .foregroundStyle(Palette.hex(0xFCA5A5))
                .pill(Palette.hex(0xF87171))
                .hoverTip("В среща: \(meeting.title)", "до \(meeting.end.formatted(date: .omitted, time: .shortened)) · още \(left) мин")
            } else if let meeting = meetings.upcoming(at: now) {
                let minutes = max(1, Int(ceil(meeting.start.timeIntervalSince(now) / 60)))
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    count
                    Text("·")
                    Text("\(minutes) мин")
                }
                .foregroundStyle(Palette.hex(0xFDBA74))
                .pill(Palette.hex(0xF97316))
                .hoverTip("\(meeting.title) след \(minutes) мин",
                          "\(meeting.start.formatted(date: .omitted, time: .shortened))–\(meeting.end.formatted(date: .omitted, time: .shortened))")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    count
                }
                .hoverTip(meetings.access ? "\(meetings.today.count) срещи днес" : "Няма достъп до календара", schedule)
            }
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(calendarHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { calendarHovered = $0 }
        .onTapGesture {
            let meeting = meetings.current(at: now) ?? meetings.upcoming(at: now)
            open(meeting?.url?.absoluteString ?? Self.calendarWeb)
        }
    }
}

private extension View {
    func pill(_ color: Color) -> some View {
        lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
