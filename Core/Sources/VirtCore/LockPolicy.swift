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
/// Nothing here is saved: a new launch starts locked, so there's nothing to remember between launches.
public struct LockPolicy: Equatable, Sendable {
    /// Away this long or longer, and Virt locks when it comes back (unless a workout is going).
    public static let standardAwayLimit: TimeInterval = 15 * 60

    public var awayLimit: TimeInterval
    /// True while Training is hidden behind the lock screen.
    public private(set) var locked: Bool
    /// When the app went to the background (a clock reading in seconds); nil while it's on screen.
    public private(set) var awaySince: TimeInterval?

    /// A fresh launch: locked.
    public init(awayLimit: TimeInterval = LockPolicy.standardAwayLimit) {
        self.awayLimit = awayLimit
        locked = true
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
        if away < 0 { return true }
        return away >= limit
    }
}
