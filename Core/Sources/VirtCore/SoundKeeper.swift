import Foundation

/// The zero sound with the phone locked, and no banner (Tyler, Nov 27). iOS plays a notification's sound only with
/// words to show, so a sound-only notification is silent. Instead Virt plays the zero itself, the way interval-timer
/// apps do: while a workout is going and Virt isn't on the screen, it holds a mixable playback audio session (his music
/// keeps playing, untouched) and keeps running with a silent loop, and schedules each zero's sound at its exact moment.
///
/// The notifications stay as the safety net: each zero still has one (with its words and sound, as before build 90),
/// and while the keeper is playing it takes each one back `handOff` seconds before its sound starts, then plays the
/// sound itself. If the keeper can't start, is interrupted (a phone call) or iOS ends Virt, nothing takes the
/// notification back, so it sounds instead: a zero is never silent with Sounds on, and never sounds twice.
///
/// These are the rules; the app's side is App/BackgroundSound.swift and Engine.
public enum SoundKeeper {
    /// How long before a zero's sound the keeper takes its notification back (plenty for a timer in a running app,
    /// short enough that the notification is still there if iOS ends Virt a little earlier).
    public static let handOff: TimeInterval = 4
    /// After the session fails to start, how long before trying again.
    public static let retryAfter: TimeInterval = 10

    /// What the keeper is doing, for the Engine and the test build's status line.
    public enum State: String, Sendable {
        /// Not needed (Virt on the screen, no workout, Sounds off), or stopped.
        case off
        /// Holding the session and playing the silent loop: the zeros are its to play.
        case on
        /// iOS took the audio away (a call, Siri, an alarm): the notifications sound until it comes back.
        case interrupted
        /// The session wouldn't start: the notifications sound.
        case failed

        /// Only a playing keeper covers the zeros.
        public var covers: Bool { self == .on }
    }

    /// Whether the keeper should run: Sounds on, Virt not on the screen, and a workout going: a countdown running
    /// toward a zero, or a live workout between sets (paused, or waiting for the next set, so a rest started by
    /// the lock screen's Log set also sounds). Never outside a workout: once the page says it's over, or it's been
    /// quiet for `TimerBoard.quietLimit`, it stops.
    public static func shouldRun(soundsOn: Bool, away: Bool, board: TimerBoard, live: Bool, now: Date) -> Bool {
        guard soundsOn, away else { return false }
        if !board.alerts(now: now).isEmpty { return true }
        return live && board.midWorkout(now: now)
    }

    /// One zero's sound for the keeper to play.
    public struct Cue: Equatable, Sendable {
        /// The zero this is (its step and its moment), the same key the in-app chime uses, so it never plays twice.
        public var key: String
        public var cue: SoundCue
        /// The bundled file.
        public var file: String
        /// When the sound starts: the zero, less the sound's own lead-in (the green light starts 1.2 s early).
        public var playAt: Date
        public var zeroAt: Date
    }

    /// The key for one zero (the step's identifier and its moment).
    public static func key(identifier: String, fireAt: Date) -> String {
        "\(identifier)@\(fireAt.timeIntervalSince1970)"
    }

    /// Every zero still ahead (the running step and each `upcoming` one), with when its sound starts. A zero whose
    /// sound should already have started (inside its lead-in) is kept, to play at once: late, never missed.
    public static func cues(board: TimerBoard, style: SoundStyle, now: Date) -> [Cue] {
        board.alerts(now: now).map { a in
            Cue(key: key(identifier: a.identifier, fireAt: a.fireAt), cue: a.cue, file: style.file(a.cue),
                playAt: a.fireAt.addingTimeInterval(-style.lead(a.cue)), zeroAt: a.fireAt)
        }.sorted { $0.playAt < $1.playAt }
    }

    /// What to do with one zero's notification.
    public enum Alert: Equatable, Sendable {
        /// Nothing: Sounds off (quiet everywhere, the Lock Screen too).
        case none
        /// Keep it scheduled, with its words and its sound: the safety net (or the only sound, with no keeper).
        case schedule
        /// Take it back: the keeper is playing and the sound is near, so the keeper plays it (no banner, no double).
        case handOff
    }

    public static func alert(soundAt: Date, now: Date, soundsOn: Bool, keeper: State) -> Alert {
        guard soundsOn else { return .none }
        if keeper.covers, soundAt.timeIntervalSince(now) <= handOff { return .handOff }
        return .schedule
    }

    /// The next moment a notification should be taken back (to arm one exact timer), or nil.
    public static func nextHandOff(cues: [Cue], now: Date, keeper: State) -> Date? {
        guard keeper.covers else { return nil }
        return cues.map { $0.playAt.addingTimeInterval(-handOff) }.filter { $0 > now }.min()
    }
}
