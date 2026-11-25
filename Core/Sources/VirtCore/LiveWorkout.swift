import Foundation

/// Whether a workout is live, for the lock (Face ID never asks, and the launch clip never plays, while one is).
///
/// - A countdown running toward its zero is always live.
/// - The page says so on `today` (`live: true / false`, an optional addition from the website). Its word counts for
///   `trustLimit` after the last sign of the workout (the page's word itself, any page message, a lock-screen button),
///   so a page that was closed without saying `false` doesn't keep the lock away for ever.
/// - A page that doesn't say: Virt's own rule, `TimerBoard.midWorkout` (45 minutes after the last sign).
///
/// The answer is kept on the phone (`Memory`) so a launch after iOS ended the app, or a scene iOS built again, goes
/// straight back to the workout.
public enum LiveWorkout {
    /// The page's `live: true` holds this long after the last sign of the workout (a long break, a phone call).
    public static let trustLimit: TimeInterval = 3 * 60 * 60

    public static func isLive(pageLive: Bool?, pageSaidAt: Date?, board: TimerBoard, now: Date) -> Bool {
        if let c = board.countdown, !c.paused, let e = c.endsAt, e > now { return true }
        guard let said = pageLive else { return board.midWorkout(now: now) }
        guard said else { return false }
        guard let last = [pageSaidAt, board.lastMessageAt, board.lastButtonAt].compactMap({ $0 }).max() else { return false }
        let since = now.timeIntervalSince(last)
        return since >= 0 && since < trustLimit
    }

    /// What Virt last knew, kept in UserDefaults under `Memory.key` (a new key) as JSON.
    public struct Memory: Codable, Equatable, Sendable {
        public static let key = "virt.workout.live"

        public var live: Bool
        /// The last moment Virt saw it so.
        public var seenAt: Date
        /// True when the page said it (`live` on `today`); false when it was Virt's own 45-minute rule.
        public var fromPage: Bool

        public init(live: Bool, seenAt: Date, fromPage: Bool) {
            self.live = live; self.seenAt = seenAt; self.fromPage = fromPage
        }

        /// At a fresh launch: was a workout live when the app was last running, recently enough to still count?
        public func stillLive(now: Date) -> Bool {
            guard live else { return false }
            let since = now.timeIntervalSince(seenAt)
            return since >= 0 && since < (fromPage ? LiveWorkout.trustLimit : TimerBoard.quietLimit)
        }

        public func encoded() -> Data? { try? JSONEncoder().encode(self) }
        public static func decode(_ data: Data?) -> Memory? { data.flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } }
    }
}

/// Log set from the lock screen, the Dynamic Island or Control Center (#573): one press is one set.
///
/// - Presses within `window` of the one before (a double tap, a press iOS delivered twice) count once.
/// - Nothing is sent when Virt's board has no next set for the open exercise (after the exercise's last set, or with
///   no workout known), so presses made while the page is asleep can never log past the exercise's end.
/// - Each `log` carries its own id (and the moment it was pressed) so the page can drop a repeat.
public struct LogPress: Equatable, Sendable {
    public static let window: TimeInterval = 0.6

    /// The last press, counted or not (the window slides, so a burst of presses counts once).
    public private(set) var lastPressAt: Date?

    public init() {}

    /// Applies one press to the board (its rest starts, the next set moves on) and returns the command for the page,
    /// or nil when nothing should be logged.
    public mutating func press(board: inout TimerBoard, now: Date, id: String) -> PageCommand? {
        defer { lastPressAt = now }
        if let last = lastPressAt, now >= last, now.timeIntervalSince(last) < Self.window { return nil }
        guard board.workout != nil, board.nextSet != nil else { return nil }
        board.logSet(now: now)
        return .log(at: now, id: id)
    }
}

/// The workout timer's alerts in Notification Center. iOS plays a notification's sound only with words to show
/// (there's no sound-only notification), so each zero's alert is a real notification; Virt keeps them out of the way:
///
/// - Their own identifiers (`prefix`), category and thread, so the training-day reminders and the streak nudge are
///   never touched.
/// - Every time Virt runs (a page message, a lock-screen button, coming forward), the ones already delivered are
///   taken away, so at most the latest one is ever on the Lock Screen or in Notification Center, and none once Virt
///   is open or the workout ends.
/// - One delivered in the last `sounding` seconds stays while Virt runs in the background, so its sound isn't cut off.
public enum TimerAlerts {
    public static let prefix = "virt.timer."
    public static let category = "virt.timer"
    public static let thread = "virt.timer"
    public static let sounding: TimeInterval = 3

    public static func isTimer(_ identifier: String) -> Bool { identifier.hasPrefix(prefix) }

    /// The delivered timer alerts to take away now. `everything`: the app is open, or the workout ended.
    public static func toRemove(delivered: [(id: String, at: Date)], now: Date, everything: Bool) -> [String] {
        delivered.filter { d in
            guard isTimer(d.id) else { return false }
            if everything { return true }
            let age = now.timeIntervalSince(d.at)
            return age < 0 || age >= sounding
        }.map { $0.id }
    }
}
