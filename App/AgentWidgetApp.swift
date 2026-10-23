import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Background app that keeps the task panel on the desktop: it runs the collector every minute
/// and draws the panel in a window that sits on the wallpaper, under the other windows.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sessions refresh every tick; GitHub, Jira and Slack every fourth (once a minute).
    private static let interval: TimeInterval = 15
    private var ticks = 0
    private static let originKey = "panelTopLeft"

    private let store = Store()
    private let meetings = Meetings()
    private var panel: DesktopPanel!
    private var timer: Timer?
    private var collecting = false
    private var pinWatch: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var hiddenWatch: AnyCancellable?
    private var pausedWatch: AnyCancellable?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One panel only: a second launch (another copy, a link) leaves the running one in charge.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current && !$0.isTerminated }
        if Demo.directory == nil, !others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        let host = NSHostingView(rootView: PanelView(store: store, meetings: meetings,
                                                     open: { [weak self] in self?.open($0) },
                                                     resized: { [weak self] in self?.panel?.fit($0) },
                                                     refresh: { [weak self] in self?.refreshNow() }))
        host.sizingOptions = []
        panel = DesktopPanel(content: host)
        panel.setFrameTopLeftPoint(savedTopLeft())
        pinWatch = store.$pinned.sink { [weak self] in self?.panel.pin($0) }
        panel.orderFrontRegardless()
        if let demo = Demo.directory {
            Snapshot.load(from: demo.appendingPathComponent("tasks.json")).map(show)
            meetings.useDemo(demo.appendingPathComponent("meetings.json"))
            if let path = Demo.snapshotPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.snapshot(to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                }
            }
            return
        }
        Snapshot.load().map(show)
        addStatusItem()
        try? SMAppService.mainApp.register()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let frame = self?.panel.frame else { return }
                UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.originKey)
            }
        }
        meetings.start()
        collect()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.store.paused else { return }  // closed: no updates until it's opened again
                self.ticks += 1
                self.collect(local: self.ticks % 4 != 0)
                if self.ticks % 4 == 0 { self.meetings.reload() }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.host == "refresh" }) { collect() }
        if urls.contains(where: { $0.host == "snapshot" }) {
            let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agent-widget")
            snapshot(to: dir.appendingPathComponent("panel.png"))
            // What the calendar part sees, to check it against the Calendar app.
            let seen = meetings.today.map { ["title": $0.title, "start": $0.start.description, "end": $0.end.description,
                                             "link": $0.url?.absoluteString ?? ""] }
            try? JSONSerialization.data(withJSONObject: ["access": meetings.access, "today": seen], options: .prettyPrinted)
                .write(to: dir.appendingPathComponent("meetings.json"))
        }
    }

    /// Writes the panel as a PNG, to check the layout without screen recording
    /// (agentwidget://snapshot, or --demo DIR --snapshot OUT for the README screenshots).
    private func snapshot(to url: URL) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func show(_ snapshot: Snapshot) {
        if let accent = Palette.hex(snapshot.brand?.accent) { Palette.accent = accent }
        store.snapshot = snapshot
    }

    // MARK: Menu bar item

    /// The binoculars in the menu bar: clear lenses while the panel is open, covered while it is closed.
    /// Any click opens a menu to open or close the panel, with a short summary.
    private func addStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "BirdWatcher"
        statusItem = item
        snapshotWatch = store.$snapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateBlink() }
        }
        hiddenWatch = store.$hidden.sink { [weak self] hidden in
            guard let self else { return }
            statusItem?.button?.image = Self.menuBarIcon(lids: hidden ? 1 : 0)
            self.updateBlink()
            if hidden {
                panel.orderOut(nil)
                Tooltip.shared.hide()
            } else {
                bringOnScreen()
                panel.orderFrontRegardless()
            }
        }
        pausedWatch = store.$paused.dropFirst().sink { [weak self] paused in
            if !paused { self?.refreshNow() }  // it may have been closed for a while
        }
    }

    /// Minimal binoculars, as in the app icon: two rings, a bridge and two eyepiece ticks.
    /// `lids`: how far the lenses are covered from the top, 0 = clear, 1 = covered. Open panel = clear
    /// lenses, closed panel = covered ("eyes shut"); a blink sweeps the lids across. A template, so macOS
    /// tints it like the other menu bar icons.
    private static func menuBarIcon(lids: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            // The icon's 64-unit grid (y down), fitted to the menu bar height.
            let u: CGFloat = 0.4
            let p = { (x: CGFloat, y: CGFloat) in NSPoint(x: rect.midX + (x - 32) * u, y: rect.midY + (33 - y) * u) }
            NSColor.black.set()
            for cx: CGFloat in [19, 45] {
                let c = p(cx, 38)
                let lens = NSRect(x: c.x - 11 * u, y: c.y - 11 * u, width: 22 * u, height: 22 * u)
                let ring = NSBezierPath(ovalIn: lens.insetBy(dx: 0.8, dy: 0.8))
                ring.lineWidth = 1.6
                ring.stroke()
                if lids > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    ring.addClip()
                    NSRect(x: lens.minX, y: lens.maxY - lens.height * lids, width: lens.width, height: lens.height * lids).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            let lines = NSBezierPath()
            lines.move(to: p(29.5, 34)); lines.line(to: p(34.5, 34))
            lines.move(to: p(14, 22)); lines.line(to: p(17, 16))
            lines.move(to: p(50, 22)); lines.line(to: p(47, 16))
            lines.lineWidth = 1.6
            lines.lineCapStyle = .round
            lines.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "BirdWatcher"
        return image
    }

    // MARK: Blink

    private var blinkTimer: Timer?
    private var snapshotWatch: AnyCancellable?

    /// Someone wants you: an agent asked you something, or Slack has unread DMs or mentions.
    private var wantsAttention: Bool {
        guard let snapshot = store.snapshot else { return false }
        return snapshot.tasks.contains { $0.agent == "waiting" } || (snapshot.slack?.contains { $0.count > 0 } ?? false)
    }

    /// While someone wants you, the eye in the menu bar blinks every few seconds.
    private func updateBlink() {
        guard wantsAttention else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            statusItem?.button?.image = Self.menuBarIcon(lids: store.hidden ? 1 : 0)
            return
        }
        guard blinkTimer == nil else { return }
        blink()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blink() }
        }
    }

    /// The lids sweep across the lenses and back: shut-and-open while the panel is open,
    /// open-and-shut while it is closed.
    private func blink() {
        let frames: [CGFloat] = [0.35, 0.7, 1, 0.7, 0.35, 0]
        for (i, sweep) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { [weak self] in
                guard let self else { return }
                statusItem?.button?.image = Self.menuBarIcon(lids: store.hidden ? 1 - sweep : sweep)
            }
        }
    }

    @objc private func statusItemClicked() {
        let menu = NSMenu()
        if store.hidden {
            menu.addItem(NSMenuItem(title: L("Отвори панела", "Open panel"), action: #selector(openPanel), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: L("Скрий панела", "Hide panel"), action: #selector(hidePanel), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: L("Затвори панела (спира обновяването)", "Close panel (stops updates)"), action: #selector(closePanel), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        for line in summary() {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        let pin = NSMenuItem(title: L("Закачи над всички прозорци", "Pin above all windows"), action: #selector(togglePin), keyEquivalent: "")
        pin.state = store.pinned ? .on : .off
        menu.addItem(pin)
        menu.addItem(NSMenuItem(title: L("Обнови сега", "Refresh now"), action: #selector(refreshNow), keyEquivalent: ""))
        let language = NSMenuItem(title: L("Език", "Language"), action: nil, keyEquivalent: "")
        language.submenu = NSMenu()
        for lang in Lang.allCases {
            let item = NSMenuItem(title: lang.name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.rawValue
            item.state = lang == store.language ? .on : .off
            item.target = self
            language.submenu?.addItem(item)
        }
        menu.addItem(language)
        menu.addItem(NSMenuItem(title: L("Премести на този екран", "Move to this screen"), action: #selector(moveHere), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("За BirdWatcher", "About BirdWatcher"), action: #selector(about), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Спри приложението", "Quit BirdWatcher"), action: #selector(quit), keyEquivalent: ""))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)  // opens the menu under the icon
        statusItem?.menu = nil  // rebuilt on every click, so the summary is current
    }

    /// The menu's info lines: tasks, Slack, the next meeting, e2e.
    private func summary() -> [String] {
        guard let snapshot = store.snapshot else { return [L("Събирам данните…", "Collecting data…")] }
        let tasks = snapshot.tasks
        let waiting = tasks.filter { $0.agent == "waiting" }.count
        let working = tasks.filter { $0.agent == "working" }.count
        var lines = [L("\(tasks.count) задачи · \(working) работят · \(waiting) чакат теб", "\(tasks.count) tasks · \(working) working · \(waiting) waiting for you")]
        if store.paused { lines.append(L("Обновяването е спряно", "Updates are paused")) }
        if let unread = snapshot.slack?.reduce(0, { $0 + $1.count }), unread > 0 { lines.append(L("Slack: \(unread) непрочетени", "Slack: \(unread) unread")) }
        let now = Date()
        if let meeting = meetings.current(at: now) {
            lines.append(L("В среща: \(meeting.title) до \(meeting.end.formatted(date: .omitted, time: .shortened))", "In a meeting: \(meeting.title) until \(meeting.end.formatted(date: .omitted, time: .shortened))"))
        } else if let next = meetings.today.first(where: { $0.start > now }) {
            lines.append(L("Следва: \(next.title) в \(next.start.formatted(date: .omitted, time: .shortened))", "Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))"))
        }
        if let e2e = snapshot.stats.e2e { lines.append(e2e.running > 0 ? L("e2e: върви", "e2e: running") : e2e.ok ? L("e2e: зелено", "e2e: green") : L("e2e: червено", "e2e: red")) }
        return lines
    }

    @objc private func openPanel() {
        store.hidden = false
        store.paused = false
    }

    /// Out of sight, still up to date.
    @objc private func hidePanel() {
        store.hidden = true
    }

    /// Out of sight and no updates until it's opened again.
    @objc private func closePanel() {
        store.paused = true
        store.hidden = true
    }

    /// Opening the app again (Spotlight, Finder, Launchpad) while it runs shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return false
    }

    /// Back onto a screen if the panel was left on a display that's gone.
    private func bringOnScreen(force: Bool = false) {
        guard force || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else { return }
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameTopLeftPoint(NSPoint(x: screen.minX + 16, y: screen.maxY - 12))
    }

    @objc private func togglePin() {
        store.pinned.toggle()
    }

    @objc private func refreshNow() {
        collect()
        meetings.reload()
    }

    @objc private func moveHere() {
        openPanel()
        bringOnScreen(force: true)
        panel.orderFrontRegardless()
    }

    /// The standard About window, with what the app is for.
    @objc private func about() {
        let text = L("""
        Следи на десктопа твоите AI агенти, PR-и, Jira, Slack и срещи — и ти казва кой чака теб.

        Всяка задача е един ред: какво прави агентът, докъде е стигнала от кода до prod, \
        какво е PR-ът. Отдолу: e2e, PR-и и тикети за месеца, срещите днес и докъде е седмицата.
        """, """
        Watches your AI agents, PRs, Jira, Slack and meetings on your desktop, and tells you who's waiting for you.

        Every task is one row: what the agent is doing, how far it got from code to prod, \
        and its PR. Below: e2e, PRs and tickets this month, today's meetings and how far the week has gone.
        """)
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let link = "github.com/aleksandrenko/agent-widget"
        credits.append(NSAttributedString(string: "\n\n" + link, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://" + link)!]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "BirdWatcher", .credits: credits])
    }

    /// Switches the panel and menus now; the collector's own texts follow on its next run.
    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let lang = (sender.representedObject as? String).flatMap(Lang.init(rawValue:)) else { return }
        store.language = lang
        refreshNow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func savedTopLeft() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            return NSPointFromString(saved)
        }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: screen.minX + 16, y: screen.maxY - 12)
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    private func collect(local: Bool = false) {
        guard !collecting else { return }
        collecting = true
        let home = NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = ["\(home)/agent-widget/collector/collect.py"] + (local ? ["--local"] : [])
        process.environment = ["HOME": home, "USER": NSUserName(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                               "BIRDWATCHER_LANG": Lang.current.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: "\(home)/.agent-widget/collect.log") ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.collecting = false
                if let snapshot = Snapshot.load() { self?.show(snapshot) }
            }
        }
        do {
            try process.run()
        } catch {
            collecting = false
        }
    }
}

/// `--demo DIR` shows DIR/tasks.json and DIR/meetings.json instead of live data and touches
/// nothing else (no collector, no login item, no saved position). With `--snapshot OUT` it writes
/// the panel to OUT, without the wallpaper blur, and quits.
enum Demo {
    static let directory = value(of: "--demo").map { URL(fileURLWithPath: $0) }
    static let snapshotPath = value(of: "--snapshot")
    static var isOn: Bool { directory != nil }

    private static func value(of flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// A borderless, see-through window on the desktop layer: above the desktop icons, below
/// every app window, on all Spaces. Its height follows the panel content, growing downwards.
final class DesktopPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        pin(false)
        acceptsMouseMovedEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }

    /// Pinned floats above every app window (also over full-screen apps); unpinned lives on the
    /// desktop layer, above the icons and under every window.
    func pin(_ pinned: Bool) {
        level = pinned ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, pinned ? .fullScreenAuxiliary : .fullScreenNone]
        orderFrontRegardless()
    }

    /// Keeps the top-left corner in place when the content grows or shrinks.
    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}
