import AppKit
import SwiftUI

/// First-run setup: what the panel needs on this Mac, the team's settings, and the optional extras.
/// Opens by itself while ~/.agent-widget/config.json is missing, and from the menu bar menu.
@MainActor
final class Setup: ObservableObject {
    static var configURL: URL { dataDir.appendingPathComponent("config.json") }
    static var dataDir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agent-widget") }

    @Published var python = false
    @Published var gh = false
    @Published var ghSignedIn = false
    @Published var teamName: String?
    @Published var jiraOK: Bool?
    @Published var message: String?

    var needed: Bool { !FileManager.default.fileExists(atPath: Self.configURL.path) }

    func check() {
        python = run(Self.python, ["-c", "print(1)"]) == 0
        let gh = Self.gh
        self.gh = gh != nil
        ghSignedIn = gh.map { run($0, ["auth", "status"]) == 0 } ?? false
        teamName = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.configURL)) as? [String: Any])?["team"] as? String
    }

    static var python: String {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command in Terminal, where it can ask the person things (GitHub sign-in).
    func inTerminal(_ command: String) {
        let script = Self.dataDir.appendingPathComponent("setup.command")
        try? FileManager.default.createDirectory(at: Self.dataDir, withIntermediateDirectories: true)
        try? "#!/bin/bash\nexport PATH=/opt/homebrew/bin:/usr/local/bin:$PATH\n\(command)\necho\necho 'Готово / Done — you can close this window.'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        _ = run("/bin/chmod", ["+x", script.path])
        NSWorkspace.shared.open(script)
    }

    /// The team's settings: a JSON file with `config` (config.json) and an optional `brandSVG` (the logo).
    func loadTeam(from link: String) async {
        message = nil
        // A gist's page link works too: its /raw serves the file.
        var link = link.trimmingCharacters(in: .whitespaces)
        if link.hasPrefix("https://gist.github.com/"), !link.contains("/raw") { link += "/raw" }
        guard let url = URL(string: link), url.scheme == "https" else {
            message = L("Това не е https линк.", "That isn't an https link.")
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let preset = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = preset["config"] as? [String: Any] else {
                message = L("Линкът не води до настройки за BirdWatcher.", "The link isn't a BirdWatcher setup file.")
                return
            }
            try FileManager.default.createDirectory(at: Self.dataDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted).write(to: Self.configURL)
            if let svg = preset["brandSVG"] as? String {
                try svg.write(to: Self.dataDir.appendingPathComponent("brand.svg"), atomically: true, encoding: .utf8)
            }
            check()
        } catch {
            message = error.localizedDescription
        }
    }

    /// No team settings: the panel still shows sessions, PRs, Slack and meetings.
    func useDefaults() {
        try? FileManager.default.createDirectory(at: Self.dataDir, withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: Self.configURL)
        check()
    }

    /// Stores the Jira email and API token in the keychain and checks them against the team's Jira.
    func saveJira(email: String, token: String) async {
        _ = run("/usr/bin/security", ["add-generic-password", "-U", "-a", NSUserName(), "-s", "jira_email", "-w", email])
        _ = run("/usr/bin/security", ["add-generic-password", "-U", "-a", NSUserName(), "-s", "jira_api_token", "-w", token])
        let config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.configURL)) as? [String: Any]) ?? [:]
        guard let site = (config["jira"] as? [String: Any])?["site"] as? String, let url = URL(string: site + "/rest/api/3/myself") else {
            jiraOK = nil
            message = L("Запазено. Липсва Jira адрес в настройките на екипа.", "Saved. The team settings have no Jira address.")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let status = (try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode
        jiraOK = status == 200
    }

    /// What to paste into Claude so a scheduled task keeps the Claude limit bar filled.
    var claudePrompt: String {
        """
        Create a scheduled task with taskId "birdwatcher-usage", title "BirdWatcher: Claude limit", running every 15 minutes \
        on weekdays from 9:00 to 18:59 (cron "*/15 9-18 * * 1-5"), notifications off, with this prompt:

        You keep one small file up to date for the BirdWatcher desktop panel. Do only this, quietly, and finish fast:
        1. Load the tool `mcp__ccd_session_mgmt__get_usage` with ToolSearch (query "select:mcp__ccd_session_mgmt__get_usage") \
        and call it with no arguments.
        2. From its `plan.windows`, take the window labelled "5-hour limit" and the one labelled "Weekly · all models".
        3. Write this JSON to `\(Self.dataDir.path)/usage.json` (overwrite it), with `at` = the current time in ISO 8601 UTC:
           {"at": "...", "fiveHour": {"percent": <percentUsed>, "resetsAt": "<resetsAt>"}, "weekly": {"percent": <percentUsed>, "resetsAt": "<resetsAt>"}}
           If `plan.status` is not "ok", write {"at": "...", "error": "<status and note>"} instead.
        4. Stop. Do not message anyone, do not open or change anything else, no summary needed.
        """
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct SetupView: View {
    @ObservedObject var setup: Setup
    @ObservedObject var meetings: Meetings
    var done: () -> Void
    @State private var link = ""
    @State private var email = ""
    @State private var token = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Настройка на BirdWatcher", "Set up BirdWatcher")).font(.title2.weight(.semibold))
                        Text(L("Няколко стъпки и панелът ти е на десктопа.", "A few steps and the panel is on your desktop."))
                            .foregroundStyle(.secondary)
                    }
                }

                step(1, L("Нужни неща на този Мак", "What this Mac needs"), ok: setup.python && setup.gh && setup.ghSignedIn) {
                    check(setup.python, L("Python 3 (за събирането на данните)", "Python 3 (collects the data)"),
                          action: L("Инсталирай", "Install"), { setup.inTerminal("xcode-select --install") })
                    check(setup.gh, L("GitHub CLI (за PR-ите)", "GitHub CLI (for your PRs)"),
                          action: L("Как се инсталира", "How to install"), { NSWorkspace.shared.open(URL(string: "https://cli.github.com")!) })
                    check(setup.ghSignedIn, L("Влязъл в GitHub", "Signed in to GitHub"),
                          action: L("Влез", "Sign in"), { setup.inTerminal("gh auth login --web") })
                    Button(L("Провери отново", "Check again")) { setup.check() }.controlSize(.small)
                }

                step(2, L("Настройки на екипа", "Your team's settings"), ok: setup.teamName != nil || !setup.needed) {
                    Text(L("Постави линка, който екипът ти е споделил (Jira, e2e, лого).",
                           "Paste the link your team shared (Jira, e2e, logo)."))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://…", text: $link).textFieldStyle(.roundedBorder)
                        Button(L("Зареди", "Load")) { Task { await setup.loadTeam(from: link) } }.disabled(link.isEmpty)
                    }
                    if let team = setup.teamName {
                        Label(L("Заредено: \(team)", "Loaded: \(team)"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(L("Нямам линк — продължи без него", "I have no link — continue without one")) { setup.useDefaults() }
                            .buttonStyle(.link)
                    }
                }

                step(3, L("Jira (по желание)", "Jira (optional)"), ok: setup.jiraOK == true) {
                    Text(L("За броя отворени / затворени тикети. Създай API токен и го постави тук.",
                           "For your open / done ticket counts. Create an API token and paste it here."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(L("Създай токен", "Create a token")) {
                        NSWorkspace.shared.open(URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    }.buttonStyle(.link)
                    TextField(L("Имейл", "Email"), text: $email).textFieldStyle(.roundedBorder)
                    SecureField(L("API токен", "API token"), text: $token).textFieldStyle(.roundedBorder)
                    HStack {
                        Button(L("Запази", "Save")) { Task { await setup.saveJira(email: email, token: token); token = "" } }
                            .disabled(email.isEmpty || token.isEmpty)
                        if let ok = setup.jiraOK {
                            Text(ok ? L("Jira работи", "Jira works") : L("Jira не прие токена", "Jira didn't accept the token"))
                                .foregroundStyle(ok ? .green : .red)
                        }
                    }
                }

                step(4, L("Календар (по желание)", "Calendar (optional)"), ok: meetings.access && !meetings.today.isEmpty) {
                    Text(L("За срещите днес. Работният ти Google акаунт трябва да е в System Settings → Internet Accounts.",
                           "For today's meetings. Your work Google account must be in System Settings → Internet Accounts."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(L("Разреши календара", "Allow the calendar")) { meetings.start() }
                }

                step(5, L("Лимит на Claude (по желание)", "Claude limit (optional)"), ok: false) {
                    Text(L("Само Claude вижда лимитите си. Копирай инструкцията и я постави в Claude — той ще създаде задача, която ги записва на всеки 15 минути.",
                           "Only Claude can see its limits. Copy the instruction and paste it into Claude — it will create a task that writes them every 15 minutes."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(copied ? L("Копирано", "Copied") : L("Копирай инструкцията", "Copy the instruction")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(setup.claudePrompt, forType: .string)
                        copied = true
                    }
                }

                if let message = setup.message {
                    Text(message).font(.callout).foregroundStyle(.orange)
                }

                HStack {
                    Spacer()
                    Button(L("Готово", "Done"), action: done)
                        .keyboardShortcut(.defaultAction)
                        .disabled(setup.needed)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 640)
        .onAppear { setup.check() }
    }

    private func step(_ n: Int, _ title: String, ok: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "\(n).circle")
                    .foregroundStyle(ok ? .green : .secondary)
                    .font(.title3)
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 8, content: content).padding(.leading, 30)
        }
    }

    private func check(_ ok: Bool, _ title: String, action: String, _ fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
            Text(title)
            Spacer()
            if !ok { Button(action, action: fix).controlSize(.small) }
        }
    }
}
