import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

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
    private var updateTimer: Timer?
    private var collecting = false
    /// A full collect was asked for while one was running: it runs once that one is done.
    private var collectAgain = false
    private var pinWatch: AnyCancellable?
    private var tourWatch: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var hiddenWatch: AnyCancellable?
    private let setup = Setup()
    private var setupWindow: NSWindow?

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
        if Demo.directory == nil, Demo.setupSnapshotPath == nil, !others.isEmpty {
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
        store.window = panel
        pinWatch = store.$pinned.sink { [weak self] in self?.panel.pin($0 || Tour.shared.current != nil) }
        // During the tour the panel comes up above the windows, so the bubbles have something to point at.
        Tour.shared.panel = panel
        tourWatch = Tour.shared.$current.map { $0 != nil }.removeDuplicates().sink { [weak self] touring in
            guard let self else { return }
            panel.pin(store.pinned || touring)
        }
        panel.orderFrontRegardless()
        if let out = Demo.setupSnapshotPath {  // --setup-snapshot OUT: a picture of the setup window, then quit
            setup.check()  // offscreen, onAppear may not run before the picture
            let view = NSHostingView(rootView: SetupView(setup: setup, meetings: meetings) {})
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let demo = Demo.directory {
            Snapshot.load(from: demo.appendingPathComponent("tasks.json")).map(show)
            meetings.useDemo(demo.appendingPathComponent("meetings.json"))
            if let step = Demo.tourStep {  // --tour N: the Explorer at its Nth part
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Tour.shared.start(at: step) }
            }
            if let path = Demo.snapshotPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.snapshot(to: URL(fileURLWithPath: path))
                    if Demo.tourStep != nil {
                        let url = URL(fileURLWithPath: path)
                        Tour.shared.snapshot(to: url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-tour.png"))
                    }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        Snapshot.load().map(show)
        addStatusItem()
        NSApp.mainMenu = Self.editMenu()
        if setup.needed {
            addDesktopIcon()
            showSetup()
        }
        try? SMAppService.mainApp.register()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let frame = self?.panel.frame else { return }
                UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.originKey)
                if Tour.shared.current != nil { Tour.shared.place() }  // the bubble follows the panel
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { if Tour.shared.current != nil { Tour.shared.place() } }  // and its right edge
        }
        if store.isOn(.calendar) { meetings.start() }
        UNUserNotificationCenter.current().delegate = Updater.shared  // a click on an earlier update notification
        Updater.shared.checkIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.checkIfDue() }
        }
        collect()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.store.hidden else { return }  // out of sight: no updates until it's opened again
                self.ticks += 1
                self.collect(local: self.ticks % 4 != 0)
                if self.ticks % 4 == 0, self.store.isOn(.calendar) { self.meetings.reload(sync: true) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.host == "refresh" }) { collect() }
        if urls.contains(where: { $0.host == "setup" }) { showSetup() }
        if urls.contains(where: { $0.host == "snapshot" }) {
            let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agent-widget")
            snapshot(to: dir.appendingPathComponent("panel.png"))
            // What the calendar part sees, to check it against the Calendar app.
            try? JSONSerialization.data(withJSONObject: ["access": meetings.access, "today": meetings.diagnostics()], options: .prettyPrinted)
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
        Palette.brandAccent = Palette.hex(snapshot.brand?.accent)
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
        item.button?.toolTip = "TheWatcher"
        statusItem = item
        snapshotWatch = store.$snapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateBlink() }
        }
        hiddenWatch = store.$hidden.sink { [weak self] hidden in
            guard let self else { return }
            if hidden { Tour.shared.stop() }
            statusItem?.button?.image = Self.menuBarIcon(lids: hidden ? 1 : 0)
            self.updateBlink()
            if hidden {
                panel.orderOut(nil)
                Tooltip.shared.hide()
            } else {
                bringOnScreen()  // back onto a screen if it was left on a display that's gone
                panel.orderFrontRegardless()
                refreshNow()  // it may have been hidden for a while
            }
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
            // Short eyepieces leaning in, so it reads as binoculars.
            lines.move(to: p(15.5, 24)); lines.line(to: p(18.5, 20))
            lines.move(to: p(48.5, 24)); lines.line(to: p(45.5, 20))
            lines.lineWidth = 1.6
            lines.lineCapStyle = .round
            lines.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TheWatcher"
        return image
    }

    // MARK: Blink

    private var blinkTimer: Timer?
    private var snapshotWatch: AnyCancellable?

    /// Someone wants you: an agent asked you something, or Slack has unread DMs or mentions.
    private var wantsAttention: Bool {
        guard let snapshot = store.snapshot else { return false }
        return snapshot.tasks.contains { $0.agent == "waiting" } || (store.isOn(.slack) && snapshot.slack?.contains { $0.count > 0 } == true)
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
        if let update = Updater.shared.available {
            menu.addItem(NSMenuItem(title: L("⬆︎ Нова версия \(update.version) — изтегли", "⬆︎ New version \(update.version) — download"),
                                    action: #selector(downloadUpdate), keyEquivalent: ""))
            menu.addItem(.separator())
        }
        if store.hidden {
            menu.addItem(NSMenuItem(title: L("Отвори панела", "Open panel"), action: #selector(openPanel), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: L("Скрий панела", "Hide panel"), action: #selector(hidePanel), keyEquivalent: ""))
        }
        // Right under Open: the way back to a panel lost under other apps' windows.
        let pin = NSMenuItem(title: L("Закачи над всички прозорци", "Pin above all windows"), action: #selector(togglePin), keyEquivalent: "")
        pin.state = store.pinned ? .on : .off
        menu.addItem(pin)
        menu.addItem(.separator())
        for line in summary() {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
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
        let modules = NSMenuItem(title: L("Модули", "Modules"), action: nil, keyEquivalent: "")
        modules.submenu = NSMenu()
        for module in Module.allCases {
            let item = NSMenuItem(title: module.name, action: #selector(toggleModule(_:)), keyEquivalent: "")
            item.representedObject = module.rawValue
            item.state = store.isOn(module) ? .on : .off
            item.target = self
            modules.submenu?.addItem(item)
        }
        menu.addItem(modules)
        let themes = NSMenuItem(title: L("Теми", "Themes"), action: nil, keyEquivalent: "")
        themes.submenu = NSMenu()
        for theme in Theme.all {
            let item = NSMenuItem(title: theme.name, action: #selector(pickTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.id
            item.state = theme.id == store.theme ? .on : .off
            item.target = self
            themes.submenu?.addItem(item)
        }
        menu.addItem(themes)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Настройка…", "Setup…"), action: #selector(showSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("Провери за нова версия", "Check for updates"), action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("За TheWatcher", "About TheWatcher"), action: #selector(about), keyEquivalent: ""))
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
        if store.isOn(.slack), let unread = snapshot.slack?.reduce(0, { $0 + $1.count }), unread > 0 { lines.append(L("Slack: \(unread) непрочетени", "Slack: \(unread) unread")) }
        let now = Date()
        if store.isOn(.calendar) {
            if let meeting = meetings.current(at: now) {
                lines.append(L("В среща: \(meeting.title) до \(meeting.end.formatted(date: .omitted, time: .shortened))", "In a meeting: \(meeting.title) until \(meeting.end.formatted(date: .omitted, time: .shortened))"))
            } else if let next = meetings.today.first(where: { $0.start > now }) {
                lines.append(L("Следва: \(next.title) в \(next.start.formatted(date: .omitted, time: .shortened))", "Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))"))
            }
        }
        if store.isOn(.e2e), let e2e = snapshot.stats.e2e { lines.append(e2e.running > 0 ? L("e2e: върви", "e2e: running") : e2e.ok ? L("e2e: зелено", "e2e: green") : L("e2e: червено", "e2e: red")) }
        if store.isOn(.portal), let prod = snapshot.stats.prod, let date = prod.date {
            lines.append(prod.running ? L("prod: качва се", "prod: deploying") : "prod: \(Footer.age(Date().timeIntervalSince(date)))")
        }
        return lines
    }

    @objc private func openPanel() {
        store.hidden = false
    }

    /// Out of sight, and no updates until it's opened again.
    @objc private func hidePanel() {
        store.hidden = true
    }

    /// Opening the app again (Spotlight, Finder, Launchpad) while it runs shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return false
    }

    /// Back onto a screen if the panel was left on a display that's gone.
    private func bringOnScreen() {
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else { return }
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameTopLeftPoint(NSPoint(x: screen.minX + 16, y: screen.maxY - 12))
    }

    /// Pinning also shows a hidden panel and brings it back from a display that's gone, so it ends up in sight.
    @objc private func togglePin() {
        store.pinned.toggle()
        guard store.pinned else { return }
        if store.hidden { store.hidden = false } else { bringOnScreen() }
    }

    private func refreshNow() {
        collect()
        if store.isOn(.calendar) { meetings.reload(sync: true) }
    }

    /// First launch: a link to the app on the Desktop, as the installer used to make.
    private func addDesktopIcon() {
        let link = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/TheWatcher")
        guard (try? link.checkResourceIsReachable()) != true else { return }
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: Bundle.main.bundleURL)
    }

    /// Never shown (the app has no menu bar), but Cmd+X/C/V/A/Z in text fields go through it:
    /// without it the setup window's token field can't be pasted into.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())  // the app menu slot
        main.addItem(item)
        return main
    }

    /// The setup window: on first launch, and from the menu.
    @objc private func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "TheWatcher"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(setup: setup, meetings: meetings) { [weak self] in
                self?.setupWindow?.close()
                self?.store.hidden = false
                self?.refreshNow()
            })
            window.center()
            setupWindow = window
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
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
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "TheWatcher", .credits: credits])
    }

    /// A module on or off: it leaves the panel now, and the collector stops (or starts) fetching it.
    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let module = (sender.representedObject as? String).flatMap(Module.init(rawValue:)) else { return }
        if store.modulesOff.contains(module) { store.modulesOff.remove(module) } else { store.modulesOff.insert(module) }
        if module == .calendar, store.isOn(.calendar) { meetings.start() }  // asks for access the first time
        updateBlink()
        refreshNow()
    }

    @objc private func downloadUpdate() {
        Updater.shared.download()
    }

    /// Asks GitHub now; says what it found, since a check that finds nothing is otherwise silent.
    @objc private func checkForUpdates() {
        Task {
            let reached = await Updater.shared.check()
            // Off the Task: a modal alert inside it would hold up every other main-thread job (the collector, the panel).
            RunLoop.main.perform { MainActor.assumeIsolated { self.showUpdateAlert(reached: reached) } }
        }
    }

    private func showUpdateAlert(reached: Bool) {
        let alert = NSAlert()
        if !reached {
            alert.messageText = L("Не успях да стигна до GitHub", "Couldn't reach GitHub")
            alert.informativeText = L("Опитай пак по-късно.", "Try again later.")
        } else if let update = Updater.shared.available {
            alert.messageText = L("Има нова версия: \(update.version)", "A new version is out: \(update.version)")
            alert.informativeText = L("Имаш \(Updater.installed). Изтегли DMG-а, отвори го и пусни TheWatcher в Applications върху стария.",
                                      "You have \(Updater.installed). Download the DMG, open it and drag TheWatcher into Applications over the old one.")
            alert.addButton(withTitle: L("Изтегли", "Download"))
            alert.addButton(withTitle: L("По-късно", "Later"))
        } else {
            alert.messageText = L("Имаш последната версия (\(Updater.installed))", "You have the latest version (\(Updater.installed))")
        }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, Updater.shared.available != nil { Updater.shared.download() }
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.theme = id
    }

    /// Switches the panel and menus now; the collector's own texts follow on its next run.
    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let lang = (sender.representedObject as? String).flatMap(Lang.init(rawValue:)) else { return }
        store.language = lang
        refreshNow()
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

    /// The collector ships inside the app; a clone at ~/agent-widget is used only when running from source.
    private static var collector: String {
        Bundle.main.path(forResource: "collect", ofType: "py", inDirectory: "collector")
            ?? NSHomeDirectory() + "/agent-widget/collector/collect.py"
    }

    private func collect(local: Bool = false) {
        guard !collecting else {
            if !local { collectAgain = true }
            return
        }
        collecting = true
        if !local { store.refreshing = true }
        let home = NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Setup.python)
        process.arguments = [Self.collector] + (local ? ["--local"] : [])
        process.environment = ["HOME": home, "USER": NSUserName(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                               "THEWATCHER_LANG": Lang.current.rawValue,
                               "THEWATCHER_OFF": store.modulesOff.map(\.rawValue).sorted().joined(separator: ",")]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: "\(home)/.agent-widget/collect.log") ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.collecting = false
                self.store.refreshing = false
                if let snapshot = Snapshot.load() { self.show(snapshot) }
                if self.collectAgain {
                    self.collectAgain = false
                    self.collect()
                }
            }
        }
        do {
            try process.run()
        } catch {
            collecting = false
            store.refreshing = false
        }
    }
}

/// `--demo DIR` shows DIR/tasks.json and DIR/meetings.json instead of live data and touches
/// nothing else (no collector, no login item, no saved position). With `--snapshot OUT` it writes
/// the panel to OUT, without the wallpaper blur, and quits.
enum Demo {
    static let directory = value(of: "--demo").map { URL(fileURLWithPath: $0) }
    static let snapshotPath = value(of: "--snapshot")
    static let setupSnapshotPath = value(of: "--setup-snapshot")
    static let tourStep = value(of: "--tour").flatMap(Int.init)
    /// --theme ID: the demo in that theme (payhawk-dark-green, payhawk-day, native).
    static let theme = value(of: "--theme")
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: Store.minWidth, height: 200),
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
        if isVisible { orderFrontRegardless() }  // a hidden panel stays hidden
    }

    /// Keeps the top-left corner in place when the content grows or shrinks.
    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}
