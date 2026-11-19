import Foundation

/// Something Virt asks studio Training's page to do, as a `kinetic:command` event (the website's
/// docs/kinetic/bridge.md). The lock-screen buttons are `timer`; Siri, the widgets and the reminders add
/// `startToday` and `rest` (wayloncore/tyleralocke#533). A page that doesn't know one ignores it.
public enum PageCommand: Equatable, Sendable {
    case timer(TimerCommand)
    /// Open today's workout and start it.
    case startToday
    /// Start a rest timer of this many seconds.
    case rest(seconds: Int)
    /// Log the next set, as if tapped at `at` (wayloncore/tyleralocke#573).
    case log(at: Date)

    /// The JavaScript that hands it to the page.
    public var script: String {
        switch self {
        case .timer(let c): return c.script
        case .startToday:
            return "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: 'startToday' }));"
        case .rest(let s):
            return "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: { command: 'rest', seconds: \(s) } }));"
        case .log(let at):
            let ms = Int((at.timeIntervalSince1970 * 1000).rounded())
            return "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: { command: 'log', at: \(ms) } }));"
        }
    }
}

/// Rest lengths Siri and Shortcuts can ask for.
public enum RestRequest {
    public static let standard = 90
    public static let range = 5...1800

    /// The seconds to use: what he asked for, else the preset, else 90; kept between 5 seconds and 30 minutes.
    public static func seconds(_ asked: Int?, preset: Int? = nil) -> Int {
        let s = asked ?? preset ?? standard
        return min(range.upperBound, max(range.lowerBound, s))
    }
}

/// Commands that wait for the page. Siri or a widget can open Virt before Training has loaded (or while it's still on
/// the sign-in), so a command is held until the page is ready, then sent once. A rest is sent with the time it has
/// left, so a rest that waited still ends when it would have.
public struct CommandQueue: Equatable, Sendable {
    /// A start that waited longer than this (a slow sign-in, say) is dropped rather than starting a surprise workout.
    public static let waitLimit: TimeInterval = 5 * 60
    /// A rest with less than this left isn't worth sending.
    public static let shortestRest = 5

    public enum Waiting: Equatable, Sendable {
        case startToday(since: Date)
        case rest(endsAt: Date)
    }

    public private(set) var waiting: [Waiting] = []
    /// True once the page has loaded and can take commands.
    public private(set) var ready = false

    public init() {}

    /// A new page is loading: hold commands until it's ready.
    public mutating func pageLoading() { ready = false }

    /// The page is ready. Returns what to send now.
    public mutating func pageReady(now: Date) -> [PageCommand] {
        ready = true
        return drain(now: now)
    }

    /// Adds a command (replacing one of the same kind) and returns what to send now.
    public mutating func add(_ w: Waiting, now: Date) -> [PageCommand] {
        waiting.removeAll { Self.sameKind($0, w) }
        waiting.append(w)
        return drain(now: now)
    }

    /// Everything waiting, if the page is ready (and then nothing waits any more).
    public mutating func drain(now: Date) -> [PageCommand] {
        guard ready else {
            waiting.removeAll { if case .startToday(let since) = $0 { return now.timeIntervalSince(since) > Self.waitLimit }; return false }
            return []
        }
        let out: [PageCommand] = waiting.compactMap {
            switch $0 {
            case .startToday(let since):
                return now.timeIntervalSince(since) <= Self.waitLimit ? .startToday : nil
            case .rest(let end):
                let left = Int(end.timeIntervalSince(now).rounded(.up))
                return left >= Self.shortestRest ? .rest(seconds: left) : nil
            }
        }
        waiting = []
        return out
    }

    static func sameKind(_ a: Waiting, _ b: Waiting) -> Bool {
        switch (a, b) {
        case (.startToday, .startToday), (.rest, .rest): return true
        default: return false
        }
    }
}

/// Virt's own links: `virt://today` (the widgets), `virt://start` (start today's workout), `virt://rest?seconds=90`,
/// and `virt://settings` (Virt's settings and tips).
public enum AppLink: Equatable, Sendable {
    case today
    case start
    case rest(seconds: Int)
    case settings

    public static let scheme = "virt"

    public var url: URL {
        switch self {
        case .today: return URL(string: "virt://today")!
        case .start: return URL(string: "virt://start")!
        case .rest(let s): return URL(string: "virt://rest?seconds=\(s)")!
        case .settings: return URL(string: "virt://settings")!
        }
    }

    public static func parse(_ url: URL) -> AppLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let what = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        switch what {
        case "today", "": return .today
        case "start": return .start
        case "settings": return .settings
        case "rest":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let s = q?.first { $0.name == "seconds" }?.value.flatMap(Int.init)
            return .rest(seconds: RestRequest.seconds(s))
        default: return nil
        }
    }

    /// The Home Screen quick actions (Info.plist UIApplicationShortcutItems), by their type.
    public static func quickAction(_ type: String) -> AppLink? {
        switch type {
        case "com.tyleralocke.virt.start": return .start
        case "com.tyleralocke.virt.rest": return .rest(seconds: RestRequest.standard)
        case "com.tyleralocke.virt.settings": return .settings
        default: return nil
        }
    }
}
