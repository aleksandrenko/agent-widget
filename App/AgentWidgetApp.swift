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
