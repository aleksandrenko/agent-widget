import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    static let pinnedKey = "pinnedAboveWindows"

    @Published var snapshot: Snapshot?
    /// A full collect (GitHub, Jira, Slack) is running: the header's refresh icon turns.
    @Published var refreshing = false
    /// Pinned: the panel floats above every window. Unpinned: it sits on the desktop, under them.
    @Published var pinned = !Demo.isOn && UserDefaults.standard.bool(forKey: pinnedKey) {
        didSet { UserDefaults.standard.set(pinned, forKey: Self.pinnedKey) }
    }
    /// Dragged on the panel's right edge, so longer titles fit.
    @Published var width = Demo.isOn ? minWidth : max(minWidth, CGFloat(UserDefaults.standard.object(forKey: widthKey) as? Double ?? 0)) {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }
    static let widthKey = "panelWidth"
    /// Narrowest the panel goes: the footer still fits on one line with its roomy gaps.
    static let minWidth: CGFloat = 400
    /// Dragged on the panel's bottom edge: the items scroll between the header and the footer.
    /// nil (double-click the bottom edge) fits the panel to its content.
    @Published var height: CGFloat? = Demo.isOn ? nil : (UserDefaults.standard.object(forKey: heightKey) as? Double).map { CGFloat($0) } {
        didSet { height.map { UserDefaults.standard.set(Double($0), forKey: Self.heightKey) } ?? UserDefaults.standard.removeObject(forKey: Self.heightKey) }
    }
    static let heightKey = "panelHeight"
    static let minHeight: CGFloat = 160
    /// Tallest the panel goes: from its top down to the bottom of the screen it is on (it grows downwards).
    var maxHeight: CGFloat {
        guard let window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return 2000 }
        return max(Self.minHeight, window.frame.maxY - screen.minY - 8)
    }
    /// The panel's height as laid out, where a drag on the bottom edge starts from.
    var laidOutHeight: CGFloat = 0
    /// The panel's window: resizing from the left or top edge moves it.
    weak var window: NSWindow?
    /// The modules turned off in the menu bar menu → Modules.
    @Published var modulesOff = Set((UserDefaults.standard.stringArray(forKey: Module.offKey) ?? []).compactMap(Module.init(rawValue:))) {
        didSet { UserDefaults.standard.set(modulesOff.map(\.rawValue).sorted(), forKey: Module.offKey) }
    }

    func isOn(_ module: Module) -> Bool { !modulesOff.contains(module) }
    /// The look, picked in the menu bar menu → Themes; changing it redraws the panel.
    @Published var theme = Theme.current.id {
        didSet { UserDefaults.standard.set(theme, forKey: Theme.key) }
    }
    /// The UI language, picked in the menu bar menu; changing it redraws the panel.
    @Published var language = Lang.current {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Lang.key) }
    }
    /// Closed with the panel's X; opened again from the menu bar ticket.
    @Published var hidden = !Demo.isOn && UserDefaults.standard.bool(forKey: hiddenKey) {
        didSet { UserDefaults.standard.set(hidden, forKey: Self.hiddenKey) }
    }
    static let hiddenKey = "panelHidden"
}

// MARK: - Palette

/// A look for the panel, picked in the menu bar menu → Themes. To add one: a value here, listed in `all`.
struct Theme {
    var id: String
    var name: String
    /// The accent: header mark, pinned pin, week bar, tour outline. A team's brand.accent in config.json wins.
    var accent: UInt32
    /// Dark glass with light text, or light glass with dark text.
    var dark: Bool
    /// The tint of the outer glass and of the task layer on it, and how much of each covers what's behind.
    var tint: UInt32
    var tasksTint: UInt32
    var opacity: (outer: Double, tasks: Double) = (0.8, 0.9)
    /// The still glow from the top-left corner.
    var glow: [(color: UInt32, opacity: Double, center: UnitPoint, radius: CGFloat)] = []

    static let payhawkGlow: [(color: UInt32, opacity: Double, center: UnitPoint, radius: CGFloat)] = [
        (0x3B82F6, 0.75, .topLeading, 0.65),
        (0x8B5CF6, 0.55, UnitPoint(x: 0.55, y: 0.12), 0.5),
        (0x14B8A6, 0.50, UnitPoint(x: 0.12, y: 0.72), 0.5),
        (0x22C55E, 0.35, UnitPoint(x: 0.4, y: 0.55), 0.38),
    ]
    static let payhawkDarkGreen = Theme(id: "payhawk-dark-green", name: "Payhawk Dark Green", accent: 0x3DDC84, dark: true,
                                        tint: 0x080D1A, tasksTint: 0x080D1A, glow: payhawkGlow)
    /// The same panel in daylight: light glass and dark text, the same glow, softer.
    static let payhawkDay = Theme(id: "payhawk-day", name: "Payhawk Day", accent: 0x3DDC84, dark: false,
                                  tint: 0xEDF1F8, tasksTint: 0xFFFFFF, glow: payhawkGlow.map { ($0.color, $0.opacity * 0.45, $0.center, $0.radius) })
    /// Plain, like the system's own widgets: flat grey, almost opaque, no glow.
    static let native = Theme(id: "native", name: "Native", accent: 0x30D158, dark: true,
                              tint: 0x2C2C2E, tasksTint: 0x3A3A3C, opacity: (0.97, 1))
    static let all = [payhawkDarkGreen, payhawkDay, native]
    static let key = "theme"

    static var current: Theme {
        all.first { $0.id == (Demo.theme ?? UserDefaults.standard.string(forKey: key)) } ?? payhawkDarkGreen
    }
}

enum Palette {
    /// Text and lines on the glass: white on the dark themes, near-black on the light ones.
    static var ink: Color { Theme.current.dark ? .white : hex(0x0F172A) }
    /// The second line of a row, the Slack message.
    static var muted: Color { Theme.current.dark ? hex(0x8FA3BF) : hex(0x52627A) }
    /// A status colour on the glass: the light shade on dark glass, the deeper one on light glass.
    static func onGlass(_ dark: UInt32, _ light: UInt32) -> Color { hex(Theme.current.dark ? dark : light) }
    static var track: Color { ink.opacity(0.12) }
    static var fill: Color { ink.opacity(0.45) }
    /// Outer glass: the theme's tint over the blurred wallpaper (Payhawk: 80%, so 20% shows through).
    static var outerLayer: Color { hex(Theme.current.tint).opacity(Theme.current.opacity.outer) }
    /// The task layer on top of it (Payhawk: 90%, 10% see-through).
    static var tasksLayer: Color { hex(Theme.current.tasksTint).opacity(Theme.current.opacity.tasks) }

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static func agent(_ state: String) -> (color: Color, light: Color, label: String) {
        switch state {
        case "working": (hex(0x1D4ED8), hex(0x5B8DEF), L("Агентът работи", "The agent is working"))
        case "waiting": (hex(0xC2410C), hex(0xF59E5B), L("Агентът чака теб", "The agent is waiting for you"))
        case "done": (hex(0x15803D), hex(0x4ADE80), L("Агентът е готов", "The agent is done"))
        default: (hex(0x2F3542), hex(0x5B6475), L("Няма агент по задачата", "No agent on this task"))
        }
    }

    /// The team's brand accent (config.json → brand.accent), else the theme's: header mark, pinned pin, week bar.
    static var brandAccent: Color?
    static var accent: Color { brandAccent ?? hex(Theme.current.accent) }

    static func hex(_ string: String?) -> Color? {
        guard let string, let value = UInt32(string.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        return hex(value)
    }

    static func jira(_ state: String) -> (color: Color, meaning: String) {
        switch state {
        case "progress": (hex(0x3B82F6), L("синьо = в работа", "blue = in progress"))
        case "review": (hex(0xA78BFA), L("лилаво = чака review", "violet = waiting for review"))
        case "staging": (hex(0x4ADE80), L("зелено = на staging", "green = on staging"))
        case "done": (hex(0x2DD4BF), L("тюркоаз = готово", "teal = done"))
        case "blocked": (hex(0xF87171), L("червено = блокиран", "red = blocked"))
        case "unknown": (hex(0x3A3A3A), L("тъмно = няма връзка с Jira", "dark = no connection to Jira"))
        default: (hex(0x6B6B6B), L("сиво = не е започнат", "grey = not started"))
        }
    }

    static func github(_ state: String) -> (color: Color, meaning: String) {
        switch state {
        case "draft": (hex(0x6B6B6B), L("сиво = draft", "grey = draft"))
        case "review": (hex(0x93C5FD), L("светлосиньо = чака AI review", "light blue = waiting for AI review"))
        case "changes": (hex(0xFB923C), L("оранжево = AI review иска промени", "orange = AI review wants changes"))
        case "ci": (hex(0xFBBF24), L("жълто = CI върви", "yellow = CI running"))
        case "fail": (hex(0xF87171), L("червено = CI пада или конфликт", "red = CI failing or a conflict"))
        case "ready": (hex(0x4ADE80), L("зелено = approved и зелен CI, готов за merge", "green = approved and CI green, ready to merge"))
        case "merged": (hex(0xA78BFA), L("лилаво = merged, на staging", "violet = merged, on staging"))
        case "prod": (hex(0x2DD4BF), L("тюркоаз = на prod", "teal = on prod"))
        default: (hex(0x3A3A3A), L("тъмно = няма PR", "dark = no PR"))
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
    /// With a height of its own: how much taller the list is than its space, and how much of it is below the fold.
    @State private var overflow = CGPoint.zero

    var body: some View {
        VStack(spacing: 0) {
            Header(brand: store.snapshot?.brand, count: store.snapshot?.tasks.count, pinned: $store.pinned, refreshing: store.refreshing,
                   close: { store.hidden = true }, refresh: refresh, help: { Tour.shared.current == nil ? Tour.shared.start() : Tour.shared.stop() })
            if let snapshot = store.snapshot {
                // With a height of its own the items scroll and the footer stays put; else the panel fits them.
                if let height = store.height.map({ min($0, store.maxHeight) }) {
                    ScrollView { items(snapshot) }
                        .scrollIndicators(.automatic)
                        .onScrollGeometryChange(for: CGPoint.self, of: { geo in
                            CGPoint(x: geo.contentSize.height - geo.containerSize.height,
                                    y: geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height)
                        }) { _, value in overflow = value }
                        .overlay(alignment: .bottom) {
                            if overflow.y > 1 {  // more below: a fade and "see all", back to fitting the content
                                SeeAll { store.height = height + overflow.x <= store.maxHeight ? nil : store.maxHeight }
                            }
                        }
                } else {
                    items(snapshot)
                }
                Footer(stats: snapshot.stats, errors: snapshot.errors, meetings: meetings, isOn: store.isOn, open: open)
            } else {
                placeholder(L("Събирам данните…", "Collecting data…"))
                if store.height != nil { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, WeekLine.height)
        .frame(width: store.width, height: store.height.map { min($0, store.maxHeight) }, alignment: .top)
        .background(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                Glass()
                EdgeGlow()
            }
        }
        .overlay(alignment: .bottom) { WeekLine().tourStop("week", inset: 0) }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.ink.opacity(0.18), lineWidth: 0.5))
        .overlay {
            ZStack {
                ForEach(ResizeHandle.Position.allCases, id: \.self) { position in
                    ResizeHandle(position: position, store: store).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
                }
            }
        }
        .gesture(WindowDragGesture())  // drag the panel from anywhere; a click still reaches rows and icons
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            store.laidOutHeight = size.height
            resized(size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(store.theme)  // the colours come from the theme, not from the views' inputs: redraw them all
        .coordinateSpace(.named(Tour.space))
        .onPreferenceChange(TourFrames.self) { frames in MainActor.assumeIsolated { Tour.shared.frames = frames } }
    }

    /// The tasks on their darker layer, then the Slack lines.
    private func items(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Separator() }
                    TaskRow(task: task, open: open, tour: index == 0)
                }
                if snapshot.tasks.isEmpty {
                    placeholder(L("Няма активни задачи", "No active tasks"))
                }
            }
            .padding(.horizontal, 6)
            // The lift is on the layer's shape only: a shadow on the list would outline every row.
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.tasksLayer)
                .shadow(color: Palette.ink.opacity(0.06), radius: 6)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))  // row tints reach the layer's edges
            // Same hairline as the outer glass, brighter at the top, plus a soft lift so the layer stands out.
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Palette.ink.opacity(0.22), Palette.ink.opacity(0.08)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            )
            if store.isOn(.slack), let slack = snapshot.slack, !slack.isEmpty {
                SlackList(items: slack, open: open).tourStop("slack", inset: 2)
                Separator().padding(.horizontal, 6)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.6))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

/// Top strip: the brand mark and name on the left, the Mac user's full name, the pin, the Explorer ? and
/// the ✕ on the right.
/// The mark is ~/.agent-widget/brand.svg when there is one.
struct Header: View {
    var brand: Snapshot.Brand?
    /// How many tasks the panel shows, next to the name.
    var count: Int?
    @Binding var pinned: Bool
    var refreshing = false
    var close: () -> Void
    var refresh: () -> Void
    var help: () -> Void = {}
    @State private var pinHovered = false
    @State private var helpHovered = false
    @State private var closeHovered = false
    @State private var headerHovered = false

    var body: some View {
        // One 22 pt row, everything centred on it. The P lines up with the status squares below
        // and the pin with the GitHub icons.
        HStack(spacing: 0) {
          // Everything but the pin and ✕: double-click to collect fresh data now.
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
            (Text("TheWatcher").foregroundColor(Palette.ink) + Text(count.map { " (\($0))" } ?? "").foregroundColor(Palette.ink.opacity(0.5)))
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 7)
            // Barely there: a spinning arc while it refreshes, still on hover as the double-click hint.
            TimelineView(.animation(paused: !refreshing)) { context in
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Palette.ink.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(refreshing ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360 : 0))
            }
            .frame(width: 9, height: 9)
            .opacity(refreshing || headerHovered ? 1 : 0)
            .padding(.leading, 5)
            Spacer(minLength: 8)
            (Text(Image(systemName: "person.fill")).font(.system(size: 10)).baselineOffset(1.5) + Text(" " + (Demo.isOn ? "Jamie Rivera" : NSFullUserName())).font(.system(size: 12)))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .lineLimit(1)
          }
          .contentShape(Rectangle())
          .tourStop("header")
          .hoverTip(L("Двоен клик → обнови данните сега", "Double-click → refresh now"), L("сесии, PR-и, Slack и срещи", "sessions, PRs, Slack and meetings"))
          .onHover { headerHovered = $0 }
          .onTapGesture(count: 2) {
              refresh()
              Tooltip.shared.show(title: L("Обновявам…", "Refreshing…"))
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Tooltip.shared.hide() }
          }
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(45))
                .foregroundStyle(pinned ? Palette.accent : Palette.ink.opacity(0.7))
                .frame(width: 18, height: 22)
                .background(Circle().fill(Palette.ink.opacity(pinHovered ? 0.08 : 0)))
                .contentShape(Circle())
                .padding(.leading, 10)  // the two buttons sit together, apart from the name
                .onHover { inside in
                    pinHovered = inside
                    if inside {
                        Tooltip.shared.show(title: pinned ? L("Над всички прозорци", "Above all windows") : L("На десктопа, под прозорците", "On the desktop, under the windows"),
                                            detail: pinned ? L("клик → върни го на десктопа", "click → back to the desktop") : L("клик → закачи го над всичко", "click → pin it above everything"))
                    } else {
                        Tooltip.shared.hide()
                    }
                }
                .onTapGesture {
                    pinned.toggle()
                    Tooltip.shared.hide()
                }
                .tourStop("pin", inset: 0)
            Image(systemName: "questionmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .frame(width: 18, height: 22)
                .background(Circle().fill(Palette.ink.opacity(helpHovered ? 0.08 : 0)))
                .contentShape(Circle())
                .onHover { inside in
                    helpHovered = inside
                    if inside {
                        Tooltip.shared.show(title: "Explorer", detail: L("клик → обиколка: какво е всяко нещо на панела", "click → a tour of what each part of the panel is"))
                    } else {
                        Tooltip.shared.hide()
                    }
                }
                .onTapGesture {
                    Tooltip.shared.hide()
                    help()
                }
                .tourStop("help", inset: 0)
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .frame(width: 18, height: 22)
                .background(Circle().fill(Palette.ink.opacity(closeHovered ? 0.08 : 0)))
                .contentShape(Circle())
                .onHover { inside in
                    closeHovered = inside
                    if inside {
                        Tooltip.shared.show(title: L("Затвори панела", "Close panel"), detail: L("и спира обновяването; отваря се от бинокъла горе", "and stops updates; open it again from the menu bar"))
                    } else {
                        Tooltip.shared.hide()
                    }
                }
                .onTapGesture {
                    Tooltip.shared.hide()
                    Tour.shared.stop()
                    close()
                }
                .tourStop("close", inset: 0)
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
    static var patches: [(color: UInt32, opacity: Double, center: UnitPoint, radius: CGFloat)] { Theme.current.glow }

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

/// Over the bottom of a list that goes on below the fold: the list fades out into the glass, with a
/// "see all" pill that makes the panel tall enough for all of it.
struct SeeAll: View {
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, Palette.outerLayer.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .allowsHitTesting(false)
            HStack(spacing: 4) {
                Text(L("виж всички", "see all"))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.ink.opacity(hovered ? 1 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Palette.ink.opacity(hovered ? 0.2 : 0.12), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .padding(.bottom, 6)
        }
    }
}

/// The panel's edges and corners: drag any of them to resize the panel, the cursor turning into the
/// matching resize arrows over it. The left and top ones move the panel's corner along. Double-click an
/// edge or corner that changes the height to fit the height to the content again.
struct ResizeHandle: View {
    /// Which way the edge moves: -1 left / up, 1 right / down, 0 not at all.
    enum Position: CaseIterable {
        case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

        var x: Int { [.left, .topLeft, .bottomLeft].contains(self) ? -1 : [.right, .topRight, .bottomRight].contains(self) ? 1 : 0 }
        var y: Int { [.top, .topLeft, .topRight].contains(self) ? -1 : [.bottom, .bottomLeft, .bottomRight].contains(self) ? 1 : 0 }
        var alignment: Alignment {
            switch self {
            case .top: .top
            case .bottom: .bottom
            case .left: .leading
            case .right: .trailing
            case .topLeft: .topLeading
            case .topRight: .topTrailing
            case .bottomLeft: .bottomLeading
            case .bottomRight: .bottomTrailing
            }
        }
        var cursor: SwiftUI.FrameResizePosition {
            switch self {
            case .top: .top
            case .bottom: .bottom
            case .left: .leading
            case .right: .trailing
            case .topLeft: .topLeading
            case .topRight: .topTrailing
            case .bottomLeft: .bottomLeading
            case .bottomRight: .bottomTrailing
            }
        }
    }

    static let widths: ClosedRange<CGFloat> = Store.minWidth...720
    var position: Position
    @ObservedObject var store: Store
    /// Where the drag started: the mouse on the screen, the panel's frame and its height as laid out.
    @State private var start: (mouse: NSPoint, frame: NSRect, height: CGFloat)?

    var body: some View {
        let corner = position.x != 0 && position.y != 0
        Color.clear
            .frame(width: position.x == 0 ? nil : corner ? 14 : 6, height: position.y == 0 ? nil : corner ? 14 : 3)
            .frame(maxWidth: position.x == 0 ? .infinity : nil, maxHeight: position.y == 0 ? .infinity : nil)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: position.cursor))
            .onTapGesture(count: 2) { if position.y != 0 { store.height = nil } }
            // The screen's mouse position, not the drag's: the panel moves under it for the left and top edges.
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    guard let window = store.window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                    let mouse = NSEvent.mouseLocation
                    let from = start ?? (mouse, window.frame, store.height ?? store.laidOutHeight)
                    start = from
                    var frame = from.frame
                    if position.x != 0 {
                        frame.size.width = min(Self.widths.upperBound, max(Self.widths.lowerBound, from.frame.width + CGFloat(position.x) * (mouse.x - from.mouse.x)))
                        if position.x < 0 { frame.origin.x = from.frame.maxX - frame.width }
                        store.width = frame.width
                    }
                    if position.y != 0 {
                        // Up to the screen's edge on the side that moves: the top for the top edge, the bottom for the bottom one.
                        let tallest = position.y < 0 ? from.height + screen.maxY - from.frame.maxY : from.frame.maxY - screen.minY - 8
                        frame.size.height = min(tallest, max(Store.minHeight, from.height - CGFloat(position.y) * (mouse.y - from.mouse.y)))
                        frame.origin.y = (position.y < 0 ? from.frame.maxY + frame.height - from.height : from.frame.maxY) - frame.height
                        store.height = frame.height
                    }
                    window.setFrame(frame, display: true)  // size and corner at once, so the far edge stays put
                }
                .onEnded { _ in start = nil })
    }
}

struct Separator: View {
    var body: some View {
        Palette.ink.opacity(0.08).frame(height: 0.5)
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
        view.appearance = NSAppearance(named: Theme.current.dark ? .vibrantDark : .vibrantLight)
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: Theme.current.dark ? .vibrantDark : .vibrantLight)
    }
}

// MARK: - Week line

struct WeekLine: View {
    static var days: [String] { [L("Понеделник", "Monday"), L("Вторник", "Tuesday"), L("Сряда", "Wednesday"), L("Четвъртък", "Thursday"), L("Петък", "Friday")] }
    static let workday = (start: 9.0, end: 18.0)
    static let height: CGFloat = 12

    /// The five day names, each centred in its fifth of the bar.
    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(Self.days, id: \.self) { day in
                Text(day).font(.system(size: 8, weight: .semibold)).tracking(0.2)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let week = Self.progress(context.date)
            ZStack(alignment: .leading) {
                Palette.track
                GeometryReader { geo in Palette.accent.frame(width: geo.size.width * week.fraction) }
                // Faint dark ticks between the five days, to see how far today's slice has got.
                GeometryReader { geo in
                    ForEach(1..<5) { day in
                        Rectangle().fill(.black.opacity(0.5)).frame(width: 2)
                            .offset(x: geo.size.width * Double(day) / 5 - 1)
                    }
                }
                // The day names twice: pale over the track, dark over the filled part, cut where the fill ends.
                labels.foregroundStyle(Color(white: 0.82))
                GeometryReader { geo in
                    labels.foregroundStyle(.black.opacity(0.8))
                        .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * week.fraction) }
                }
            }
            .frame(height: Self.height)
            .hoverTip { x, width in
                let day = min(4, Int(x / width * 5))
                let state: String
                if week.weekday > 4 || day < week.weekday {
                    state = L("минал", "past")
                } else if day > week.weekday {
                    state = L("предстои", "to come")
                } else {
                    state = L("\(context.date.formatted(date: .omitted, time: .shortened)) · \(Int(week.today * 100))% от деня", "\(context.date.formatted(date: .omitted, time: .shortened)) · \(Int(week.today * 100))% of the day")
                }
                return ("\(Self.days[day]) · \(state)", L("седмицата: \(Int(week.fraction * 100))%", "the week: \(Int(week.fraction * 100))%"))
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
    /// The first row: its parts are the tour's task stops.
    var tour = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            StatusSquare(task: task).tourStop(tour ? "status" : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 4) {
                    if let key = task.key {
                        Text(key)
                        Text("·")
                    }
                    Text(task.note.isEmpty && task.key == nil ? L("без тикет", "no ticket") : task.note).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                StageLine(task: task).frame(width: 150).tourStop(tour ? "stage" : nil).padding(.top, 2)
            }
            .tourStop(tour ? "task" : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                IconButton(name: "github", color: Palette.github(task.github?.state ?? "none").color,
                           tip: ("GitHub: \(githubTitle)", Palette.github(task.github?.state ?? "none").meaning)) {
                    task.github.map { open($0.url) }
                }
                .tourStop(tour ? "github" : nil, inset: 0)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(LinearGradient(stops: [.init(color: Palette.agent(task.agent).color.opacity(0.22), location: 0),
                                           .init(color: Palette.agent(task.agent).color.opacity(0.06), location: 0.35),
                                           .init(color: .clear, location: 0.6)],
                                   startPoint: .leading, endPoint: .trailing))
        .background(hovered ? Palette.ink.opacity(0.04) : .clear)
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { open(task.url) }
    }

    private var githubTitle: String {
        guard let github = task.github else { return L("няма PR", "no PR") }
        return github.count > 1 ? L("\(github.label) (+\(github.count - 1) PR-а)", "\(github.label) (+\(github.count - 1) PRs)") : github.label
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
        .foregroundStyle(Color.white)
        .frame(width: 32, height: 32)
        .background(LinearGradient(colors: [look.light, look.color], startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), .clear, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
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
            .background(Circle().fill(Palette.ink.opacity(hovered ? 0.08 : 0)))
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
                let current = task.stage < Stage.names.count ? Stage.names[task.stage] : L("на prod", "on prod")
                return ("\(index + 1). \(Stage.names[index]) · \(Stage.describe(index: index, stage: task.stage, state: task.stageState))",
                        L("сега: \(current)", "now: \(current)"))
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
            (Text(item.channel.map { "\(item.name) · #\($0)" } ?? item.name).fontWeight(.semibold).foregroundColor(Palette.ink)
                + Text(" · \(item.text)").foregroundColor(Palette.muted))
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(item.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.onGlass(0xF6B3C8, 0xBE185D))
                .frame(minWidth: 14, minHeight: 14)
                .padding(.horizontal, 4)
                .background(Palette.hex(0xE01E5A).opacity(0.32), in: Capsule())
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(Palette.ink.opacity(hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .hoverTip(item.channel == nil ? L("Лично съобщение", "Direct message") : L("Споменаване в #\(item.channel!)", "Mention in #\(item.channel!)"), L("клик → Slack", "click → Slack"))
        .onTapGesture { open(item.url) }
    }
}

// MARK: - Usage pill

/// How much of the Claude 5-hour session limit is used: a small rounded outline (18 × 9 pt) that
/// fills up as the limit is used, green, then orange past 70%, red past 90%. Hover shows the %.
/// Grey when the reading is over 3 hours old: the scheduled task that writes it isn't running.
struct UsagePill: View {
    var usage: Snapshot.Usage

    var body: some View {
        let used = min(1, max(0, usage.fiveHour.percent / 100))
        let stale = usage.stale == true
        let color = stale ? Palette.hex(0x6B6B6B) : used >= 0.9 ? Palette.hex(0xF87171) : used >= 0.7 ? Palette.hex(0xFB923C) : Palette.accent
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.85), lineWidth: 1)  // the footer icons' colour
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: max(2, 14 * used))
                .padding(2)
        }
        .frame(width: 18, height: 9)
        .opacity(stale ? 0.5 : 1)
        .hoverTip(stale ? L("Лимит на Claude: \(Int(usage.fiveHour.percent))% (старо)", "Claude limit: \(Int(usage.fiveHour.percent))% (old)") : "\(Int(usage.fiveHour.percent))%",
                  stale ? L("последно прочетено \(Footer.age(Date().timeIntervalSince1970 - usage.at)) назад;\nзадачата birdwatcher-usage не го обновява",
                            "last read \(Footer.age(Date().timeIntervalSince1970 - usage.at)) ago;\nthe birdwatcher-usage task isn't updating it") : nil)
    }
}

// MARK: - Footer

/// The blinking round clock next to something that is running now (an e2e run, a deploy).
struct RunningClock: View {
    var body: some View {
        TimelineView(.animation) { context in
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.hex(0x60A5FA))
                .opacity(0.6 + 0.4 * cos(context.date.timeIntervalSinceReferenceDate * .pi / 0.6))
        }
    }
}

struct Footer: View {
    var stats: Snapshot.Stats
    var errors: [String: String]
    @ObservedObject var meetings: Meetings
    var isOn: (Module) -> Bool = { _ in true }
    var open: (String) -> Void
    @State private var e2eHovered = false
    @State private var prodHovered = false
    @State private var mobileHovered = false
    @State private var calendarHovered = false
    static let calendarWeb = "https://calendar.google.com/calendar/r/day"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
          VStack(spacing: 0) {
            // Roomy gaps when the panel is wide enough, tighter ones as it gets narrower.
            ViewThatFits(in: .horizontal) {
                row(context.date, spacing: 21)
                row(context.date, spacing: 14)
                row(context.date, spacing: 9)
                row(context.date, spacing: 6)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.ink.opacity(0.85))
            .lineLimit(1)
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 6))
          }
        }
    }

    private func row(_ now: Date, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if isOn(.e2e), stats.e2e != nil || errors["e2e"] != nil { e2e.tourStop("e2e") }
            if isOn(.portal), stats.prod != nil || errors["prod"] != nil { prod(now).tourStop("prod") }
            if isOn(.mobile), stats.mobile != nil || errors["mobile"] != nil { mobile(now).tourStop("mobile") }
            if isOn(.prs) {
                counter(icon: "arrow.triangle.pull", counts: stats.prs, title: L("Твоите PR-и", "Your PRs"), error: errors["prCounts"])
                    .tourStop("prs")
            }
            if isOn(.jira) { jiraCounter.tourStop("jira") }  // "–" until Jira answers (needs the API token); hover says why
            Spacer(minLength: 0)
            HStack(spacing: 6) {  // the limit bar sits close to the calendar
                if isOn(.limit), let ai = stats.ai { UsagePill(usage: ai).tourStop("limit") }
                if isOn(.calendar) { calendar(now).tourStop("calendar") }
            }
            .fixedSize()  // never squeezed: the meeting count stays readable
        }
    }

    private var e2e: some View {
        let state = stats.e2e
        let color: Color = state == nil ? .gray : state!.ok ? Palette.onGlass(0x4ADE80, 0x16A34A) : Palette.onGlass(0xF87171, 0xDC2626)
        return HStack(spacing: 3) {
            Text("e2e").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            if (state?.running ?? 0) > 0 {
                RunningClock()
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Palette.ink.opacity(e2eHovered ? 0.08 : 0), in: Capsule())
        .padding(.horizontal, -5)
        .onHover { e2eHovered = $0 }
        .hoverTip(e2eTitle, e2eDetail)
        .onTapGesture { state?.url.map(open) }
    }

    private var e2eTitle: String {
        guard let state = stats.e2e else { return L("e2e: няма данни", "e2e: no data") }
        return state.ok ? L("e2e: последният run мина", "e2e: the last run passed") : L("e2e: последният run падна", "e2e: the last run failed")
    }

    private var e2eDetail: String? {
        guard let state = stats.e2e else { return errors["e2e"] }
        var lines: [String] = []
        if let recent = state.recent { lines.append(L("\(state.passed ?? 0) от последните \(recent) минаха", "\(state.passed ?? 0) of the last \(recent) passed")) }
        if state.running > 0 { lines.append(L("\(state.running) вървят в момента", "\(state.running) running now")) }
        lines.append(state.running > 0 ? L("клик → текущият run", "click → the running run") : L("клик → последният run", "click → the last run"))
        return lines.joined(separator: "\n")
    }

    /// Browser icon + "2ч": how long ago the last release reached production, with the e2e clock while one goes out.
    private func prod(_ now: Date) -> some View {
        let state = stats.prod
        let date = state?.date
        return HStack(spacing: 4) {
            Image(systemName: "safari")
            if let date { Text(Self.age(now.timeIntervalSince(date))) }
            if state?.running == true {
                RunningClock()
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Palette.ink.opacity(prodHovered ? 0.08 : 0), in: Capsule())
        .padding(.horizontal, -5)
        .onHover { prodHovered = $0 }
        .hoverTip(prodTitle(now), prodDetail)
        .onTapGesture { state?.url.map(open) }
    }

    private func prodTitle(_ now: Date) -> String {
        guard let state = stats.prod, let date = state.date else { return L("prod: няма данни", "prod: no data") }
        if state.running { return L("Нова версия се качва на прод", "A new version is going to prod") }
        let age = Self.age(now.timeIntervalSince(date))
        return L("На прод от \(age) · \(state.tag)", "On prod for \(age) · \(state.tag)")
    }

    private var prodDetail: String? {
        guard let state = stats.prod, let date = state.date else { return errors["prod"] }
        var lines = [L("последен деплой: \(state.tag), \(date.formatted(date: .abbreviated, time: .shortened))",
                       "last deploy: \(state.tag), \(date.formatted(date: .abbreviated, time: .shortened))")]
        let prs = state.prs ?? []
        let mine = prs.filter(\.mine), others = prs.filter { !$0.mine }
        if !mine.isEmpty {
            lines.append(L("\nТвоите (\(mine.count)):", "\nYours (\(mine.count)):"))
            lines += mine.map { "● \($0.title) #\($0.number)" }
        }
        if let total = state.total, total > mine.count {
            lines.append(mine.isEmpty ? L("\n\(total) PR-а:", "\n\(total) PRs:") : L("\nДруги (\(total - mine.count)):", "\nOthers (\(total - mine.count)):"))
            lines += others.map { "• \($0.title)" }
            if total - mine.count > others.count { lines.append(L("+\(total - mine.count - others.count) още", "+\(total - mine.count - others.count) more")) }
        }
        lines.append(L("\nклик → release notes", "\nclick → release notes"))
        return lines.joined(separator: "\n")
    }

    /// Phone icon, green or red by the mobile e2e workflow's last run, + how long the newest store release
    /// has been out; the clock blinks while a release candidate is being promoted or an e2e run is going.
    private func mobile(_ now: Date) -> some View {
        let state = stats.mobile
        let e2e = state?.e2e
        let color: Color = e2e?.lastAt == nil ? Palette.ink.opacity(0.85) : e2e!.ok ? Palette.onGlass(0x4ADE80, 0x16A34A) : Palette.onGlass(0xF87171, 0xDC2626)
        return HStack(spacing: 4) {
            Image(systemName: "iphone").foregroundStyle(color)
            if let date = state?.date { Text(Self.age(now.timeIntervalSince(date))) }
            if state?.running == true || (e2e?.running ?? 0) > 0 { RunningClock() }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Palette.ink.opacity(mobileHovered ? 0.08 : 0), in: Capsule())
        .padding(.horizontal, -5)
        .onHover { mobileHovered = $0 }
        .hoverTip(mobileTitle(now), mobileDetail)
        .onTapGesture { state?.url.map(open) }
    }

    private func mobileTitle(_ now: Date) -> String {
        guard let state = stats.mobile, let date = state.date else { return L("Мобилно: няма данни", "Mobile: no data") }
        if state.running { return L("Мобилно: нова версия се пуска в магазините", "Mobile: a new version is going to the stores") }
        let age = Self.age(now.timeIntervalSince(date))
        return L("Мобилно: в магазините от \(age) · \(state.tag)", "Mobile: in the stores for \(age) · \(state.tag)")
    }

    private var mobileDetail: String? {
        guard let state = stats.mobile, let date = state.date else { return errors["mobile"] }
        var lines = [L("пусната: \(date.formatted(date: .abbreviated, time: .shortened))", "released: \(date.formatted(date: .abbreviated, time: .shortened))")]
        if let candidate = state.candidate { lines.append(L("следваща: \(candidate)", "next: \(candidate)")) }
        if let e2e = state.e2e, e2e.lastAt != nil {
            let when = e2e.lastAt.flatMap { ISO8601DateFormatter().date(from: $0) }.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
            lines.append(e2e.ok ? L("\ne2e: последният run мина (\(when))", "\ne2e: the last run passed (\(when))")
                                : L("\ne2e: последният run падна (\(when))", "\ne2e: the last run failed (\(when))"))
            if let recent = e2e.recent { lines.append(L("\(e2e.passed ?? 0) от последните \(recent) минаха", "\(e2e.passed ?? 0) of the last \(recent) passed")) }
            if e2e.running > 0 { lines.append(L("\(e2e.running) вървят в момента", "\(e2e.running) running now")) }
        }
        lines.append(L("\nклик → таговете в GitHub", "\nclick → the tags on GitHub"))
        return lines.joined(separator: "\n")
    }

    /// Hover lines for a list: the first 15, then "+N още" for the rest of `total`.
    static func list(_ lines: [String], total: Int) -> [String] {
        if lines.isEmpty && total == 0 { return [L("няма", "none")] }
        let shown = Array(lines.prefix(15))
        return total > shown.count ? shown + [L("+\(total - shown.count) още", "+\(total - shown.count) more")] : shown
    }

    /// 25 мин, 3ч, 2д.
    static func age(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return L("\(minutes) мин", "\(minutes)m") }
        if minutes < 48 * 60 { return L("\(minutes / 60)ч", "\(minutes / 60)h") }
        return L("\(minutes / 1440)д", "\(minutes / 1440)d")
    }

    /// Open / Done this week / Done this month, like the PR counter.
    private var jiraCounter: some View {
        HStack(spacing: 4) {
            Image(systemName: "ticket")
            if let jira = stats.jira {
                Text("\(jira.open)") + Text("/\(jira.week)/\(jira.month)").foregroundColor(Palette.ink.opacity(0.45))
            } else {
                Text("–")
            }
        }
        .hoverTip(L("Твоите Jira тикети", "Your Jira tickets"),
                  stats.jira.map { jira in
                      ([L("\(jira.open) отворени · \(jira.week) Done тази седмица · \(jira.month) Done този месец",
                         "\(jira.open) open · \(jira.week) done this week · \(jira.month) done this month"), ""]
                       + Self.list((jira.openList ?? []).map { "• \($0.key) \($0.title) · \($0.status)" }, total: jira.open))
                          .joined(separator: "\n")
                  }
                      ?? [errors["jira"], L("клик → въведи имейл и токен", "click → enter your email and token")].compactMap { $0 }.joined(separator: "\n"))
        .onTapGesture { if stats.jira == nil { open("agentwidget://setup") } }
    }

    private func counter(icon: String, counts: Snapshot.Counts?, title: String, error: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            if let counts {
                Text("\(counts.open)") + Text("/\(counts.week)/\(counts.month)").foregroundColor(Palette.ink.opacity(0.45))
            } else {
                Text("–")
            }
        }
        .hoverTip(title, counts.map { counts in
            let open = counts.openList ?? []
            return ([L("\(counts.open) отворени · \(counts.week) merged тази седмица · \(counts.month) merged този месец",
                       "\(counts.open) open · \(counts.week) merged this week · \(counts.month) merged this month"),
                     L("\nОтворени (\(open.count)):", "\nOpen (\(open.count)):")]
                    + Self.list(open.map { "• \($0.title) · \($0.repo) #\($0.number)" }, total: open.count)
                    + [L("\nклик → твоите PR-и в GitHub", "\nclick → your PRs on GitHub")])
                .joined(separator: "\n")
        } ?? error)
        .contentShape(Rectangle())
        .onTapGesture { open(Self.myPRs) }
    }

    /// GitHub's list of my open PRs across every repo.
    static let myPRs = "https://github.com/pulls?q=is%3Apr+is%3Aopen+author%3A%40me+archived%3Afalse"

    /// How many of today's meetings are still ahead (the one you're in counts, finished ones don't); turns
    /// into an orange "3 · 4 мин" pill before a meeting and a red one during it.
    private func calendar(_ now: Date) -> some View {
        let remaining = meetings.remaining(at: now)
        let count = Text(meetings.access ? "\(remaining.count)" : "–")
        let schedule = remaining.map { "\($0.start.formatted(date: .omitted, time: .shortened)) \($0.title)" }.joined(separator: "\n")
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
                    Text(L("в среща", "in a meeting"))
                }
                .foregroundStyle(Palette.onGlass(0xFCA5A5, 0xB91C1C))
                .pill(Palette.hex(0xF87171))
                .hoverTip(L("В среща: \(meeting.title)", "In a meeting: \(meeting.title)"), L("до \(meeting.end.formatted(date: .omitted, time: .shortened)) · още \(left) мин", "until \(meeting.end.formatted(date: .omitted, time: .shortened)) · \(left) min left"))
            } else if let meeting = meetings.upcoming(at: now) {
                let minutes = max(1, Int(ceil(meeting.start.timeIntervalSince(now) / 60)))
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    count
                    Text("·")
                    Text(L("\(minutes) мин", "\(minutes) min"))
                }
                .foregroundStyle(Palette.onGlass(0xFDBA74, 0xC2410C))
                .pill(Palette.hex(0xF97316))
                .hoverTip(L("\(meeting.title) след \(minutes) мин", "\(meeting.title) in \(minutes) min"),
                          "\(meeting.start.formatted(date: .omitted, time: .shortened))–\(meeting.end.formatted(date: .omitted, time: .shortened))")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    count
                }
                .hoverTip(meetings.access ? L("Още \(remaining.count) срещи днес", "\(remaining.count) more meetings today") : L("Няма достъп до календара", "No access to the calendar"), schedule)
            }
        }
        .padding(.horizontal, 4)
        .background(Palette.ink.opacity(calendarHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
