import Foundation

/// The zero sound with the phone locked, and no banner (Tyler, Nov 27). iOS plays a notification's sound only with
/// words to show, so a sound-only notification is silent, and Tyler doesn't want timer notifications at all ("I don't
/// want all those notifications"). So Virt plays the zero itself, the way interval-timer apps do: while a workout is
/// going and Virt isn't on the screen, it holds a mixable playback audio session (his music keeps playing, untouched)
/// and keeps running with a silent loop, and schedules each zero's sound at its exact moment.
///
/// There's no notification for a timer zero in any case: if the keeper can't play (a phone call took the audio, or
/// iOS ended Virt), that zero is silent, and the keeper comes back after. The Live Activity still shows the timer.
///
/// These are the rules; the app's side is App/BackgroundSound.swift and Engine.
public enum SoundKeeper {
    /// After the session fails to start, how long before trying again.
    public static let retryAfter: TimeInterval = 10

    /// What the keeper is doing, for the Engine and the test build's status line.
    public enum State: String, Sendable {
        /// Not needed (Virt on the screen, no workout, Sounds off), or stopped.
        case off
        /// Holding the session and playing the silent loop: the zeros are its to play.
        case on
        /// iOS took the audio away (a call, Siri, an alarm): the zeros are silent until it comes back.
        case interrupted
        /// The session wouldn't start (tried again after `retryAfter`).
        case failed

        /// Only a playing keeper is playing the zeros.
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

    /// One zero's sound for the keeper to play: its count-in and the zero sound, as one sound (`LeadIn.compose`).
    public struct Cue: Equatable, Sendable {
        /// The zero this is (its step and its moment), the same key the in-app chime uses, so it never plays twice.
        public var key: String
        public var cue: SoundCue
        /// The bundled zero sound (for Chime and Digital's rest-ends, the green light, which is its own count-in).
        public var file: String
        /// The tick played three times before it, or nil when `file` is its own count-in.
        public var tick: String?
        /// How many beats of the count-in fit (`LeadIn.beats`): 3, or fewer when there isn't room.
        public var beats: Int
        /// When the sound starts: its first beat that fits (3 s before the zero when all three do), or the zero.
        public var playAt: Date
        public var zeroAt: Date

        public init(key: String, cue: SoundCue, file: String, tick: String?, beats: Int, playAt: Date, zeroAt: Date) {
            self.key = key
            self.cue = cue
            self.file = file
            self.tick = tick
            self.beats = beats
            self.playAt = playAt
            self.zeroAt = zeroAt
        }
    }

    /// The key for one zero (the step's identifier and its moment).
    public static func key(identifier: String, fireAt: Date) -> String {
        "\(identifier)@\(fireAt.timeIntervalSince1970)"
    }

    /// Every zero still ahead (the running step and each `upcoming` one), each with its count-in and when it starts.
    /// The count-in keeps its rhythm and always ends on the zero: with less room (inside the last 3 s already, a short
    /// step, a zero close after another) it starts on the next whole beat that fits (`LeadIn.beats`), or it's just the
    /// zero sound, on time.
    public static func cues(board: TimerBoard, style: SoundStyle, now: Date) -> [Cue] {
        board.alerts(now: now).map { a in
            let n = LeadIn.beats(zero: a.fireAt, now: now, length: a.length)
            return Cue(key: key(identifier: a.identifier, fireAt: a.fireAt), cue: a.cue, file: style.file(a.cue),
                       tick: style.countInTick(a.cue), beats: n, playAt: a.fireAt.addingTimeInterval(-TimeInterval(n)),
                       zeroAt: a.fireAt)
        }.sorted { $0.playAt < $1.playAt }
    }

    /// What to do with a zero's sound already scheduled or playing when the zeros ahead change (a pause, resume, ±15,
    /// skip, Log set, Sounds off, or just a page message): keep it, or stop it. `wanted`: the same zero (step and
    /// moment) is still ahead. `sounding`: it has started and is playing.
    /// - The same zero still ahead: keep it, whether it's waiting to start or already counting in (its count-in is
    ///   never restarted or cut short by a refresh; `beats` only shrinks as time passes).
    /// - That zero gone (paused, moved by ±15, skipped, Sounds off): stop it, so a count-in never runs on into a zero
    ///   that isn't there; unless its zero has already come, so the zero sound is ringing: that plays out.
    public static func keeps(playAt: Date, zeroAt: Date, sounding: Bool, wanted: Bool, now: Date) -> Bool {
        if wanted { return sounding || playAt > now }
        return sounding && now >= zeroAt
    }
}
