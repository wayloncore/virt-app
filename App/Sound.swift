import AVFoundation
import UIKit
import VirtCore

/// Virt's own sounds while the app is open: each zero's sound with its three-second count-in (Nov 27: the ticks at
/// -3, -2 and -1 s, or the green light's three tones, then the zero sound on the zero; VirtCore's `LeadIn`), a tiny
/// click when a set is logged, and a warm finish. They mix with his music: plain ambient sound normally; for a zero's
/// sound, with music playing, the music ducks from the count-in's first beat until the zero sound ends, and comes back.
/// The lock-screen sound keeper (BackgroundSound) plays the same count-in and zero, as the same one sound.
/// Nov 27 ("The sound could be louder"): each style's files got one gain (+5.5 dB for Chime and Digital), so the loudest
/// zero is at -1.5 dBFS and the balance inside the style is as it was; `volume` sets how loud each
/// cue plays against the others.
///
/// Settings (Virt's settings sheet; saved-data rule: new keys only): `sounds.enabled` (on unless turned off) and
/// `sounds.style` (SoundStyle's raw value).
@MainActor final class SoundBoard {
    static let shared = SoundBoard()

    enum Key {
        static let enabled = "sounds.enabled"
        static let style = "sounds.style"
    }

    private var players: [String: AVAudioPlayer] = [:]
    /// The zero's sound playing now with the app open (its count-in, then the zero), and which zero it is.
    private var countIn: (player: AVAudioPlayer, key: String, zeroAt: Date)?
    private var restoreWork: DispatchWorkItem?
    /// For the test build's status line: the last sound played.
    private(set) var last = "none"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    var style: SoundStyle {
        get { SoundStyle(stored: UserDefaults.standard.string(forKey: Key.style)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.style); players = [:]; CountInSound.warm(newValue) }
    }

    /// The page's 3-2-1 beeps and these sounds mix with his music and follow the silent switch.
    func setUp() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        for cue in SoundCue.allCases { _ = player(cue, style: style) }
        CountInSound.warm(style)
    }

    /// A zero's sound with its count-in, now, while the app is open: from its first beat that fits (`beats`), so it
    /// ends on the zero. Engine starts it at that beat.
    @discardableResult func playZero(_ cue: SoundCue, beats: Int, key: String, zeroAt: Date) -> Bool {
        guard enabled, UIApplication.shared.applicationState == .active else { return false }
        let st = style
        let c = SoundKeeper.Cue(key: key, cue: cue, file: st.file(cue), tick: st.countInTick(cue), beats: beats,
                                playAt: zeroAt.addingTimeInterval(-TimeInterval(beats)), zeroAt: zeroAt,
                                tickVolume: st.tickVolume)
        guard let made = CountInSound.player(for: c) else { return false }
        let (p, at) = made
        countIn?.player.stop()
        last = "\(st.rawValue)-\(cue.rawValue) \(beats)"
        let wait = max(0, at.timeIntervalSinceNow)
        if ZeroMix.choose(otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying) == .duck {
            duck(for: wait + p.duration)
        }
        p.volume = Self.volume(cue)
        if wait > 0.02 { _ = p.play(atTime: p.deviceCurrentTime + wait) } else { _ = p.play() }
        countIn = (p, key, zeroAt)
        return true
    }

    /// Stops a count-in still before its zero when that zero isn't the one ahead any more (a pause, ±15, skip, or
    /// Sounds off). A zero sound already ringing plays out.
    func stopCountIn(keeping key: String?, now: Date) {
        guard let c = countIn else { return }
        let sounding = c.player.isPlaying
        if SoundKeeper.keeps(playAt: .distantPast, zeroAt: c.zeroAt, sounding: sounding, wanted: c.key == key, now: now) { return }
        c.player.stop()
        countIn = nil
    }

    /// Plays a cue now (only while the app is open; the sound keeper plays the zeros with it locked).
    func play(_ cue: SoundCue, style: SoundStyle? = nil, force: Bool = false) {
        guard force || (enabled && UIApplication.shared.applicationState == .active) else { return }
        let st = style ?? self.style
        guard let p = player(cue, style: st) else { return }
        last = "\(st.rawValue)-\(cue.rawValue)"
        let zero = cue == .go || cue == .rest
        if zero, ZeroMix.choose(otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying) == .duck {
            duck(for: p.duration)
        }
        p.volume = Self.volume(cue)
        p.currentTime = 0
        p.play()
    }

    /// A sample for the settings sheet (plays even with Sounds off, so he can hear a style before choosing it).
    /// The rest-ends "go" is the same green-light tone in Chime and Digital (Tyler, Nov 24), so it can't tell them
    /// apart, and the set click is too short and quiet to hear as a sample (Tyler, Nov 27: "when clicked on digital or
    /// chime no sound made"). Each style's work-ends sound is a full tone and differs in all three, so that's the sample.
    /// It's the zero sound alone, with no count-in (Nov 27): tapping through the styles plays each one straight away,
    /// and the 3-2-1 is the same tick in every style but Digital.
    func preview(_ style: SoundStyle) { play(.rest, style: style, force: true) }

    static func volume(_ cue: SoundCue) -> Float {
        switch cue {
        case .leadIn: return 0.55  // a tick on its own (the count-in bakes its beats in at LeadIn.tickVolume instead)
        case .set: return 0.6
        case .go, .rest: return 1  // the zeros at full volume (Tyler, Nov 27: he wants them loud)
        case .finish: return 0.8
        }
    }

    /// Music down for the chime, then back up (ducking needs the playback category for that moment).
    private func duck(for seconds: TimeInterval) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        try? s.setActive(true)
        restoreWork?.cancel()
        let work = DispatchWorkItem {
            // the lock-screen sound keeper took the session in the meantime (Virt went to the background): it's the
            // keeper's to hand back
            if BackgroundSound.shared.sessionHeld { return }
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            try? s.setCategory(.ambient, options: [.mixWithOthers])
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2, execute: work)
    }

    private func player(_ cue: SoundCue, style: SoundStyle) -> AVAudioPlayer? {
        let file = style.file(cue)
        if let p = players[file] { return p }
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext), let p = try? AVAudioPlayer(contentsOf: url) else {
            return nil
        }
        p.prepareToPlay()
        players[file] = p
        return p
    }
}

/// The zeros' sounds with their count-in (Tyler, Nov 27, build 95; VirtCore's `LeadIn`): one sound per zero, from -3 s
/// through the zero, built once from the style's bundled tick and zero files and kept in memory, then cut to the beats
/// that fit. One player plays the beats and the zero, so they're exactly a second apart, locked or open. Why one sound
/// and not a player per tick: a lock-screen schedule is all-or-nothing this way (a pause stops one player; a sound
/// that has started always reaches its zero), there's one `play(atTime:)` per zero to get right, and no new files
/// ship.
@MainActor enum CountInSound {
    private static var pcm: [String: (rate: Int, samples: [Float])] = [:]
    private static var whole: [String: (rate: Int, samples: [Float])] = [:]

    /// Builds a style's two count-ins ahead (at launch, and when the style changes), so the first zero has it ready.
    static func warm(_ style: SoundStyle) {
        for cue in [SoundCue.go, .rest] { _ = full(file: style.file(cue), tick: style.countInTick(cue), tickVolume: style.tickVolume) }
    }

    /// A player for this zero, and when it starts: the count-in from its first beat that fits. If a file can't be read
    /// as samples, the plain zero sound on the zero (the green light from its start, when there's room for it).
    static func player(for c: SoundKeeper.Cue) -> (AVAudioPlayer, Date)? {
        if let w = full(file: c.file, tick: c.tick, tickVolume: c.tickVolume) {
            let part = LeadIn.slice(w.samples, rate: w.rate, beats: c.beats)
            if !part.isEmpty, let p = try? AVAudioPlayer(data: LeadIn.wav(part, rate: w.rate)) {
                p.prepareToPlay()
                return (p, c.playAt)
            }
        }
        guard let url = url(c.file), let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.prepareToPlay()
        if c.tick == nil {
            guard c.beats == Int(LeadIn.seconds) else { return nil }
            return (p, c.playAt)
        }
        return (p, c.zeroAt)
    }

    private static func full(file: String, tick: String?, tickVolume: Float) -> (rate: Int, samples: [Float])? {
        let key = "\(tick ?? "-")@\(tickVolume)+\(file)"
        if let w = whole[key] { return w }
        guard let z = samples(file) else { return nil }
        var t: [Float]?
        if let tick {
            guard let s = samples(tick), s.rate == z.rate else { return nil }
            t = s.samples
        }
        let w = (rate: z.rate, samples: LeadIn.compose(tick: t, zero: z.samples, rate: z.rate, tickVolume: tickVolume))
        whole[key] = w
        return w
    }

    private static func url(_ file: String) -> URL? {
        Bundle.main.url(forResource: (file as NSString).deletingPathExtension, withExtension: (file as NSString).pathExtension)
    }

    /// A bundled file as mono float samples.
    private static func samples(_ file: String) -> (rate: Int, samples: [Float])? {
        if let s = pcm[file] { return s }
        guard let url = url(file), let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), channels = Int(f.processingFormat.channelCount)
        var out = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            for i in 0..<n { out[i] += ch[c][i] / Float(channels) }
        }
        let s = (rate: Int(f.processingFormat.sampleRate), samples: out)
        pcm[file] = s
        return s
    }
}
