import Foundation

/// The video intro's order of events (App/Intro.swift plays the clips; App/Lock.swift drives this).
///
/// 1. A fresh launch plays the launch clip (VIRT, the I, R and T wipe away, the V grows) while Face ID is already
///    asking. It ends on the large V, which is the lock screen.
/// 2. Face ID says yes: the unlock clip plays (the camera flies into the V until it's black), then Training fades in.
///    If that happens before the launch clip ends, the launch clip finishes its V landing quickly first.
/// 3. Locked again after time away: the V lock screen, no launch clip; the unlock clip on unlock.
/// 4. A tap skips the launch clip to its last frame. With Reduce Motion there's no video: cross-fades only.
///
/// Plain values, so the tests can walk every path without a phone. Nothing here is saved.
public struct IntroFlow: Equatable, Sendable {
    public enum Stage: String, Sendable {
        /// The launch clip is playing.
        case launch
        /// The lock screen: the V held still, with the Unlock button.
        case lock
        /// The unlock clip is playing (Face ID said yes).
        case unlock
        /// Training shows.
        case done
    }

    /// How fast the rest of the launch clip plays once Face ID has said yes.
    public static let hurryRate: Float = 3

    public private(set) var stage: Stage
    /// Face ID said yes while the launch clip was playing: it finishes at `hurryRate`, then the unlock clip plays.
    public private(set) var hurrying = false
    public let reduceMotion: Bool

    /// A fresh launch: the launch clip, or with Reduce Motion the lock screen at once (it fades in).
    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        stage = reduceMotion ? .lock : .launch
    }

    /// A launch that opens straight into Training: no clip and no lock screen (a workout is live, or Lock after is
    /// Never). `LockPolicy.lockedAtLaunch` decides.
    public static func open(reduceMotion: Bool) -> IntroFlow {
        var f = IntroFlow(reduceMotion: reduceMotion)
        f.stage = .done
        return f
    }

    /// The launch clip reached its last frame, by playing or by a skip.
    public mutating func launchEnded() {
        guard stage == .launch else { return }
        stage = hurrying ? .unlock : .lock
        hurrying = false
    }

    /// A tap while the launch clip plays: straight to its last frame.
    public mutating func skip() { launchEnded() }

    /// Face ID (or the passcode) said yes.
    public mutating func unlocked() {
        switch stage {
        case .launch: hurrying = true
        case .lock: stage = reduceMotion ? .done : .unlock
        case .unlock, .done: break
        }
    }

    /// The unlock clip reached black.
    public mutating func unlockEnded() {
        if stage == .unlock { stage = .done }
    }

    /// Locked again after time away: the lock screen, with no launch clip.
    public mutating func relocked() {
        stage = .lock
        hurrying = false
    }

    /// The app went to the background with a clip playing. A clip never resumes partway: it comes back on the lock
    /// screen if it's still locked, or straight to Training if Face ID had already said yes.
    public mutating func interrupted(locked: Bool) {
        guard stage == .launch || stage == .unlock else { return }
        stage = locked ? .lock : .done
        hurrying = false
    }

    /// The Unlock button shows only on the lock screen itself, not over the clips.
    public var showsUnlockButton: Bool { stage == .lock }

    /// Face ID has said yes and a clip is still finishing: the lock window stays up until it's done.
    public var playingOut: Bool { stage == .unlock || (stage == .launch && hurrying) }
}
