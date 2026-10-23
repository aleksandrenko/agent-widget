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
    private var peeking = false
    private var clickOutside: Any?

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
                                                     resized: { [weak self] in self?.panel?.fit($0) }))
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
                guard let self else { return }
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

    /// Click: bring the panel above every window until the next click elsewhere. Right click: a menu.
    private func addStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = "Agent Widget"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// A mini panel: a rounded frame with the brand mark (or ✨) on top and two task rows, each a status
    /// square and a text line. A template, so macOS tints it like the other menu bar icons.
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 26, height: 16), flipped: false) { rect in
            NSColor.black.set()
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 0.7, dy: 0.7), xRadius: 3.5, yRadius: 3.5)
            frame.lineWidth = 1.4
            frame.stroke()
            if let mark = Header.mark ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
                let height: CGFloat = 4.6
                mark.isTemplate = true
                mark.draw(in: NSRect(x: 3.6, y: 9.6, width: height * mark.size.width / max(mark.size.height, 1), height: height),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
            for y: CGFloat in [6.2, 2.8] {
                NSBezierPath(roundedRect: NSRect(x: 3.6, y: y, width: 2.6, height: 2.6), xRadius: 0.7, yRadius: 0.7).fill()
                NSBezierPath(roundedRect: NSRect(x: 7.6, y: y + 0.7, width: 14.4, height: 1.2), xRadius: 0.6, yRadius: 0.6).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agent Widget"
        return image
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            peeking ? endPeek() : peek()
        }
    }

    private func peek() {
        bringOnScreen()
        guard !store.pinned else { return panel.orderFrontRegardless() }
        peeking = true
        panel.pin(true)
        clickOutside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.endPeek() }
        }
    }

    private func endPeek() {
        if let monitor = clickOutside { NSEvent.removeMonitor(monitor) }
        clickOutside = nil
        guard peeking else { return }
        peeking = false
        panel.pin(store.pinned)
    }

    /// Back onto a screen if the panel was left on a display that's gone.
    private func bringOnScreen(force: Bool = false) {
        guard force || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else { return }
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameTopLeftPoint(NSPoint(x: screen.minX + 16, y: screen.maxY - 12))
    }

    private func showMenu() {
        let menu = NSMenu()
        let pin = NSMenuItem(title: "Закачи над всички прозорци", action: #selector(togglePin), keyEquivalent: "")
        pin.state = store.pinned ? .on : .off
        [pin,
         NSMenuItem(title: "Обнови сега", action: #selector(refreshNow), keyEquivalent: ""),
         NSMenuItem(title: "Премести на този екран", action: #selector(moveHere), keyEquivalent: ""),
         .separator(),
         NSMenuItem(title: "Изход", action: #selector(quit), keyEquivalent: "")].forEach { item in
            item.target = self
            menu.addItem(item)
        }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)  // opens the menu under the icon
        statusItem?.menu = nil  // so the next left click peeks again
    }

    @objc private func togglePin() {
        endPeek()
        store.pinned.toggle()
    }

    @objc private func refreshNow() {
        collect()
        meetings.reload()
    }

    @objc private func moveHere() {
        bringOnScreen(force: true)
        panel.orderFrontRegardless()
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
        process.environment = ["HOME": home, "USER": NSUserName(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
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
