import AppKit
@preconcurrency import UserNotifications

/// Once a day asks GitHub for the newest TheWatcher release. When it is newer than this app it says so once,
/// in a notification (click → download the DMG), and keeps an update item at the top of the menu bar menu.
@MainActor
final class Updater: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Updater()
    static let latestURL = URL(string: "https://api.github.com/repos/aleksandrenko/agent-widget/releases/latest")!
    private static let checkedKey = "updateCheckedAt"
    private static let notifiedKey = "updateNotifiedVersion"

    /// The newer release, once found: its version and where its DMG (or else its page) is.
    private(set) var available: (version: String, url: URL)?

    static var installed: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Checks when the last check was a day ago or more; called every hour.
    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: Self.checkedKey)
        guard Date().timeIntervalSince1970 - last >= 86400 else { return }
        Task { await check() }
    }

    /// false when GitHub couldn't be reached (offline, rate-limited, no release).
    @discardableResult
    func check() async -> Bool {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        struct Release: Decodable {
            var tag_name: String
            var html_url: String
            var assets: [Asset]
            struct Asset: Decodable { var name: String; var browser_download_url: String }
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return false }  // offline: try again next hour
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard Self.newer(version, than: Self.installed) else {
            available = nil
            return true
        }
        let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }?.browser_download_url
        guard let url = URL(string: dmg ?? release.html_url) else { return true }
        available = (version, url)
        if UserDefaults.standard.string(forKey: Self.notifiedKey) != version { notify(version: version, url: url) }
        return true
    }

    /// 1.0.10 is newer than 1.0.9: compared number by number.
    static func newer(_ a: String, than b: String) -> Bool {
        let parts = { (s: String) in s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    /// Downloads the new DMG: open it and drag TheWatcher into Applications, over the old one.
    func download() {
        if let url = available?.url { NSWorkspace.shared.open(url) }
    }

    /// Once per version, and only once it was really shown: a denied prompt leaves it for the next check.
    private func notify(version: String, url: URL) {
        UNUserNotificationCenter.current().delegate = self
        let content = UNMutableNotificationContent()
        content.title = L("Нова версия на TheWatcher", "A new version of TheWatcher")
        content.body = L("\(version) е готова (имаш \(Self.installed)). Натисни, за да я изтеглиш.",
                         "\(version) is out (you have \(Self.installed)). Click to download it.")
        content.userInfo = ["url": url.absoluteString]
        let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            UNUserNotificationCenter.current().add(request) { error in
                guard error == nil else { return }
                DispatchQueue.main.async { UserDefaults.standard.set(version, forKey: Self.notifiedKey) }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    /// Shown even while the app is in front (it never is, but the panel counts as active).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
