import Foundation

/// When Virt locks behind Face ID (with the iPhone's passcode as the fallback).
///
/// - A fresh launch always starts locked.
/// - Coming back after `awayLimit` or longer in the background locks it again, unless a workout is going
///   (`TimerBoard.midWorkout`): coming back between sets never asks him to unlock.
/// - Once locked, it stays locked until Face ID or the passcode says yes. Nothing else unlocks it.
///
/// Time away is measured on a clock that keeps running while the phone sleeps and can't be changed in Settings (the
/// app passes its readings in seconds), so setting the phone's clock back doesn't skip the lock. Plain values, so the
/// tests can run it against a fake clock.
///
/// The "Lock after" setting (`LockAfter`) sets `awayLimit`: right away (0), 15 minutes (the standard), an hour, or
/// never (`.infinity`). A fresh launch starts locked unless a workout is live or the setting is Never
/// (`lockedAtLaunch`).
public struct LockPolicy: Equatable, Sendable {
    /// Away this long or longer, and Virt locks when it comes back (unless a workout is going).
    public static let standardAwayLimit: TimeInterval = 15 * 60

    public var awayLimit: TimeInterval
    /// True while Training is hidden behind the lock screen.
    public private(set) var locked: Bool
    /// When the app went to the background (a clock reading in seconds); nil while it's on screen.
    public private(set) var awaySince: TimeInterval?

    /// A fresh launch: locked (or open, when `lockedAtLaunch` says so).
    public init(awayLimit: TimeInterval = LockPolicy.standardAwayLimit, locked: Bool = true) {
        self.awayLimit = awayLimit
        self.locked = locked
    }

    /// Whether a fresh launch (or a scene iOS built again) starts locked: never while a workout is live (the page said
    /// so, or Virt's own rule did, before the app was ended), and never with Lock after set to Never.
    public static func lockedAtLaunch(lockAfter: LockAfter, liveWorkout: Bool) -> Bool {
        !(liveWorkout || lockAfter == .never)
    }

    /// The app went to the background (or the phone locked with Virt open). A second call before it comes back keeps
    /// the first time, so the time away is never cut short.
    public mutating func wentAway(at clock: TimeInterval) {
        if awaySince == nil { awaySince = clock }
    }

    /// The app is coming back to the screen. Locks it if it was away too long and no workout is going. Returns
    /// whether it's locked now.
    @discardableResult
    public mutating func cameBack(at clock: TimeInterval, midWorkout: Bool) -> Bool {
        defer { awaySince = nil }
        guard !locked, let since = awaySince else { return locked }
        if Self.shouldLock(away: clock - since, limit: awayLimit, midWorkout: midWorkout) { locked = true }
        return locked
    }

    /// Face ID or the passcode said yes.
    public mutating func unlocked() {
        locked = false
        awaySince = nil
    }

    /// The rule itself: lock after `limit` away, never in the middle of a workout. A clock that seems to have gone
    /// backward locks too (it can't be trusted to say how long the app was away).
    public static func shouldLock(away: TimeInterval, limit: TimeInterval = standardAwayLimit, midWorkout: Bool) -> Bool {
        if midWorkout { return false }
        if limit == .infinity { return false }  // Lock after: Never
        if away < 0 { return true }
        return away >= limit
    }
}

/// Virt's "Lock after" setting: how long Virt can be away (in the background) before Face ID asks again. Never in the
/// middle of a workout, whatever it says. Stored in UserDefaults under `key` as the raw text (a new key; saved-data
/// rule: never rename a case's raw value).
public enum LockAfter: String, CaseIterable, Sendable {
    case rightAway = "now"
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case never

    public static let key = "lock.after"
    public static let standard: LockAfter = .fifteenMinutes

    /// A stored value read back; nothing stored, or a value from a newer Virt, is the standard 15 minutes.
    public init(stored: String?) { self = LockAfter(rawValue: stored ?? "") ?? .standard }

    public var name: String {
        switch self {
        case .rightAway: return "Right away"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        case .never: return "Never"
        }
    }

    /// The time away that locks it (LockPolicy.awayLimit). Never is `.infinity`.
    public var limit: TimeInterval {
        switch self {
        case .rightAway: return 0
        case .fifteenMinutes: return LockPolicy.standardAwayLimit
        case .oneHour: return 60 * 60
        case .never: return .infinity
        }
    }
}
