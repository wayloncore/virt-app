import Foundation

/// The video intro's order of events (App/Intro.swift plays the clips; App/Cover.swift drives this). Virt has no lock
/// of its own (Tyler, Nov 28: "Do we even need an app lock? ... Remove that"), so nothing here waits for Face ID or the
/// passcode:
///
/// 1. A fresh launch plays the launch clip (VIRT, the I, R and T wipe away, the V grows). It ends on the large V.
/// 2. Straight on, the unlock clip plays (the camera flies into the V until it's black), then Training fades in.
/// 3. A tap during the launch clip skips to its last frame, and the unlock clip plays from there.
/// 4. No clip at all, straight into Training: while a workout is live (Virt remembers it across a launch,
///    `LiveWorkout`), with Reduce Motion, and for a scene iOS builds again (the intro is the app's, once a launch).
/// 5. Going to the background mid-clip ends the intro: a clip never resumes partway, so Training is there on return.
///
/// Plain values, so the tests can walk every path without a phone. Nothing here is saved.
public struct IntroFlow: Equatable, Sendable {
    public enum Stage: String, Sendable {
        /// The launch clip is playing.
        case launch
        /// The unlock clip is playing, into black.
        case unlock
        /// Training shows.
        case done
    }

    public private(set) var stage: Stage

    /// A fresh launch with the clips (`atLaunch` decides whether there are any).
    public init() { stage = .launch }

    /// How a launch, or a scene iOS built again, opens: the clips, or straight into Training. Never a clip while a
    /// workout is live, none with Reduce Motion, and none for a scene built again.
    public static func atLaunch(liveWorkout: Bool, reduceMotion: Bool, sceneRebuilt: Bool) -> IntroFlow {
        var f = IntroFlow()
        if liveWorkout || reduceMotion || sceneRebuilt { f.stage = .done }
        return f
    }

    /// The launch clip reached its last frame, by playing or by a skip: the unlock clip plays.
    public mutating func launchEnded() {
        if stage == .launch { stage = .unlock }
    }

    /// A tap while the launch clip plays: straight to its last frame, then the unlock clip.
    public mutating func skip() { launchEnded() }

    /// The unlock clip reached black: Training.
    public mutating func unlockEnded() {
        if stage == .unlock { stage = .done }
    }

    /// The app went to the background with a clip playing: a clip never resumes partway, so it comes back to Training.
    public mutating func interrupted() { stage = .done }

    /// A clip is still playing: the intro's window stays up until it's done.
    public var playing: Bool { stage != .done }
}
