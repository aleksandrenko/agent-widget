import Foundation

/// Mirrors ~/.agent-widget/tasks.json written by collector/collect.py.
struct Snapshot: Decodable {
    var generatedAt: Double
    var brand: Brand?
    var tasks: [TaskItem]
    var slack: [SlackItem]?
    var stats: Stats
    var errors: [String: String]

    /// From config.json: the name in the header and the accent colour (#RRGGBB).
    struct Brand: Decodable {
        var name: String?
        var accent: String?
    }

    struct Stats: Decodable {
        var prs: Counts?
        var jira: JiraCounts?
        var e2e: E2E?
        var ai: Usage?
    }

    /// Claude plan limits, from the birdwatcher-usage scheduled task (refreshed every 30 min).
    struct Usage: Decodable {
        var at: Double
        var fiveHour: Window
        var weekly: Window?

        struct Window: Decodable {
            var percent: Double
            var resetsAt: String

            var resets: Date? {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
            }
        }
    }

    /// My open tickets, and the ones I closed this week and this month.
    struct JiraCounts: Decodable {
        var open: Int
        var week: Int
        var month: Int
    }

    struct Counts: Decodable {
        var week: Int
        var month: Int
    }

    struct E2E: Decodable {
        var ok: Bool
        var last: String?
        var lastAt: String?
        var url: String?
        var running: Int
        var passed: Int?
        var recent: Int?
    }

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agent-widget/tasks.json")
    }

    static func load(from url: URL = fileURL) -> Snapshot? {
        try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }
}

/// An unread Slack DM or mention: who, where (nil for a DM), the first line, how many, and its link.
struct SlackItem: Decodable, Identifiable {
    var id: String
    var name: String
    var channel: String?
    var text: String
    var count: Int
    var url: String
}

struct TaskItem: Decodable, Identifiable {
    var id: String
    var key: String?
    var title: String
    var note: String
    var agent: String
    var lastActivity: Double?
    var url: String
    var jira: Link?
    var github: GitHubLink?
    var stage: Int
    var stageState: String

    struct Link: Decodable {
        var state: String
        var label: String
        var url: String
    }

    struct GitHubLink: Decodable {
        var state: String
        var label: String
        var url: String
        var count: Int
    }
}

enum Stage {
    static let names = ["Писане на код", "Pushed", "AI review", "CI build", "On staging", "On prod"]

    /// What the stage under the cursor means for a task at `stage` in `state`.
    static func describe(index: Int, stage: Int, state: String) -> String {
        if index < stage { return "готово" }
        if index > stage { return "предстои" }
        switch state {
        case "now": return "върви сега"
        case "fail": return "падна"
        default: return "следващ, чака"
        }
    }
}
