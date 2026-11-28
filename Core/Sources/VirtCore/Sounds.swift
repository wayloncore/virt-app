import Foundation

/// Virt's sounds: one set per style, each short and quiet, bundled as .caf files (App/Sounds, where LICENSES.md says
/// where each came from). The zero sounds are also the lock-screen alerts' sound.
public enum SoundCue: String, CaseIterable, Sendable {
    /// The soft 3-2-1 ticks before zero.
    case leadIn = "tick"
    /// Zero, when a rest (or recovery) ends: back to work.
    case go
    /// Zero, when work (or a hold) ends: rest starts. Related to `go`, but falling where `go` rises.
    case rest
    /// A set logged (with a light tap).
    case set
    /// The workout saved.
    case finish

    /// A zero's sound (`go` or `rest`), the ones with a count-in.
    public var isZero: Bool { self == .go || self == .rest }

    /// Which zero sound a countdown of this kind ends with.
    public static func zero(after kind: TimerKind) -> SoundCue {
        switch kind {
        case .rest, .intervalRest, .other: return .go
        case .work, .hold: return .rest
        }
    }
}

/// The sound styles in Virt's settings. Saved-data rule: the stored value is the raw text; never rename a case.
/// `allCases` is the display order (Classic, Clean, Playful), which the page gets as `kineticApp.prefs.soundStyles`.
public enum SoundStyle: String, CaseIterable, Sendable {
    /// Clean synthesized bells, made for Virt.
    case chime
    /// The first Virt chime, for every zero.
    case classic
    /// Clean tones and clicks picked from Kenney's free (CC0) Interface Sounds.
    case digital
    // The tone styles (Tyler, Nov 27): one loud tone, synthesized for Virt (`scripts/sounds.py tones`), for both zeros.
    case digitalUp = "digital-up"
    case glass
    case sonar
    case synthRise = "synth-rise"
    case watchBeeps = "watch-beeps"
    case marimba
    case ringBell = "ring-bell"
    case buzzerHorn = "buzzer-horn"
    case arcade
    case levelUp = "level-up"
    case coinPickup = "coin-pickup"
    case victory
    case bounce
    case questJingle = "quest-jingle"

    public static let standard: SoundStyle = .chime

    /// The picker's small titles, in order.
    public enum Group: String, CaseIterable, Sendable {
        case classic = "Classic", clean = "Clean", playful = "Playful"
    }

    public var name: String {
        switch self {
        case .chime: return "Chime"
        case .classic: return "Classic"
        case .digital: return "Digital"
        case .digitalUp: return "Digital up"
        case .glass: return "Glass"
        case .sonar: return "Sonar"
        case .synthRise: return "Synth rise"
        case .watchBeeps: return "Watch beeps"
        case .marimba: return "Marimba"
        case .ringBell: return "Ring bell"
        case .buzzerHorn: return "Buzzer horn"
        case .arcade: return "Arcade"
        case .levelUp: return "Level up"
        case .coinPickup: return "Coin pickup"
        case .victory: return "Victory"
        case .bounce: return "Bounce"
        case .questJingle: return "Quest jingle"
        }
    }

    public var group: Group {
        switch self {
        case .chime, .classic: return .classic
        case .digital, .digitalUp, .glass, .sonar, .synthRise, .watchBeeps, .marimba, .ringBell, .buzzerHorn: return .clean
        case .arcade, .levelUp, .coinPickup, .victory, .bounce, .questJingle: return .playful
        }
    }

    /// The styles under one title, in display order.
    public static func styles(in group: Group) -> [SoundStyle] { allCases.filter { $0.group == group } }

    /// A tone style: its one tone is the zero sound for both zeros, and its other cues are Chime's.
    public var isTone: Bool { group != .classic && self != .digital }

    public var detail: String {
        switch self {
        case .chime: return "A green light when a rest ends, a 3-2-1 and a soft falling bell when work ends"
        case .digital: return "A green light when a rest ends, a 3-2-1 and a falling run of clean tones when work ends"
        case .classic: return "The first Virt chime"
        default: return "The same tone at both zeros, after a 3-2-1"
        }
    }

    /// How long before the zero a zero's sound starts (Tyler, Nov 27, build 95: "I need it to start around 3 seconds
    /// not 1 second"): every zero, in every style, locked or open, has a three-second count-in, a beat at -3, -2 and
    /// -1 s and the zero sound on the zero. In Chime and Digital the rest-ends zero is the green light, whose three
    /// short tones are its count-in; every other zero is the style's tick three times, then its zero sound
    /// (`LeadIn.compose`). 0 for the cues that aren't zeros (the tick itself, the set click, the finish).
    public func lead(_ cue: SoundCue) -> TimeInterval { cue.isZero ? LeadIn.seconds : 0 }

    /// The tick played before a zero's sound, or nil when the zero's file is its own count-in (the green light).
    public func countInTick(_ cue: SoundCue) -> String? {
        guard cue.isZero, file(cue) != Self.startFile else { return nil }
        return file(.leadIn)
    }

    /// A stored value read back (an unknown one, from a newer Virt, falls back to the standard style).
    public init(stored: String?) { self = SoundStyle(rawValue: stored ?? "") ?? .standard }

    /// The race-start "go" (Tyler, Nov 24: "a training green-light sound"): three short even tones, then one longer,
    /// higher go tone. It's the sound when a rest ends in Chime and Digital, in the app and on the Lock Screen.
    /// Nov 27: the same tones one second apart (`scripts/sounds.py start`), so its count-in starts 3 s before the zero.
    /// The bells it replaced (`virt-chime-go.caf`, `virt-digital-go.caf`) and the first green light (`firstStartFile`)
    /// stay in the app for a rollback.
    public static let startFile = "virt-start-go-3s.caf"
    /// The first green light (Nov 24: 0.4 s apart, the go at 1.2 s), kept untouched for a rollback; no style plays it.
    public static let firstStartFile = "virt-start-go.caf"
    /// Where the go tone starts in `startFile`: its three short tones come first, so the go tone lands on the zero.
    public static let startLead: TimeInterval = LeadIn.seconds

    /// The bundled file for a cue. Classic has one zero sound and a tone style one tone; their other cues use Chime's.
    public func file(_ cue: SoundCue) -> String {
        let zero = cue == .go || cue == .rest
        switch self {
        case .classic:
            return zero ? "virt-chime.wav" : SoundStyle.chime.file(cue)
        case .chime, .digital:
            if cue == .go { return Self.startFile }
            return "virt-\(rawValue)-\(cue.rawValue).caf"
        default:
            return zero ? "virt-\(rawValue)-zero.caf" : SoundStyle.chime.file(cue)
        }
    }

    /// Every bundled file a style uses (the tests check each is in App/Sounds).
    public var files: Set<String> { Set(SoundCue.allCases.map(file)) }

    /// The full list for the page, in display order: `[{"id":"chime","name":"Chime","group":"Classic"},…]`.
    public static var listJSON: String {
        "[" + allCases.map { s in
            "{\"id\":\(AppPrefs.quote(s.rawValue)),\"name\":\(AppPrefs.quote(s.name)),\"group\":\(AppPrefs.quote(s.group.rawValue))}"
        }.joined(separator: ",") + "]"
    }
}

/// The count-in before each zero (Tyler, Nov 27, build 95): three beats one second apart, at -3, -2 and -1 s, then the
/// zero sound exactly on the zero. In every style, with Virt open or the phone locked, for every timed zero the app
/// sounds (a rest's end, a timed work or hold's end, each interval change, and each `upcoming` step's zero).
///
/// The timing rule, in plain words: the count-in always keeps its one-second rhythm and always ends exactly on the
/// zero. When there isn't room for all of it (a countdown shorter than 3 s, a -15 that leaves less, a resume inside
/// the last 3 s, or a zero less than 3 s after the one before), it starts on the next whole beat that still fits
/// (-2 or -1), or it's just the zero sound. A beat never lands right on the step's own start (it needs `afterStart`
/// of room), so two close zeros never overlap their count-ins. Pausing stops a count-in; resuming times it again.
public enum LeadIn {
    /// The count-in's length: its first beat is this long before the zero.
    public static let seconds: TimeInterval = 3
    /// A beat needs this much time ahead of now to be scheduled (otherwise it's skipped, never played late).
    public static let ahead: TimeInterval = 0.02
    /// And this much after the step began (the previous zero, or the countdown's start), so it never sits on top of it.
    public static let afterStart: TimeInterval = 0.25
    /// How loud the beats are baked into the count-in, as a gain on the tick file (Nov 27). With the files in the
    /// balance Tyler approved (Chime's tick at -17.4 dBFS peak), 1.76 (+4.9 dB) puts the beats at -12.5, 11 dB under a
    /// tone style's zero (-1.5): clearly there over music, well under the zero. It's a gain in the samples (more than
    /// a player's volume can give); nothing clips (a tick never overlaps the zero sound).
    public static let tickVolume: Float = 1.76

    /// How many beats of the count-in still fit before this zero: 3, 2, 1 or 0 (then just the zero sound).
    /// `length`: how long the step that ends here runs, when known (it can't start before the step does).
    public static func beats(zero: Date, now: Date, length: TimeInterval?) -> Int {
        var room = zero.timeIntervalSince(now) - ahead
        if let l = length { room = min(room, l - afterStart) }
        guard room > 0 else { return 0 }
        return min(Int(seconds), Int((room + 1e-9).rounded(.down)))
    }

    /// When the count-in's sound starts: its first beat that fits, or the zero itself.
    public static func start(zero: Date, now: Date, length: TimeInterval?) -> Date {
        zero.addingTimeInterval(-TimeInterval(beats(zero: zero, now: now, length: length)))
    }

    /// The beats that play, each a whole second before the zero (for the tests and the status line).
    public static func ticks(zero: Date, now: Date, length: TimeInterval?) -> [Date] {
        let n = beats(zero: zero, now: now, length: length)
        return stride(from: n, to: 0, by: -1).map { zero.addingTimeInterval(-TimeInterval($0)) }
    }

    /// One sound for a zero, from -3 s through the zero (so one player plays it all, beats and zero exactly a
    /// second apart): the tick at 0, 1 and 2 s at `tickVolume`, then the zero sound at 3 s. With no tick, the zero's
    /// own file is already its count-in (the green light) and is used as it is. `scripts/sounds.py countin` makes the
    /// same thing for the previews.
    public static func compose(tick: [Float]?, zero: [Float], rate: Int, tickVolume: Float = tickVolume) -> [Float] {
        guard let tick else { return zero }
        let beat = rate * Int(seconds) / 3, at = beat * 3
        var out = [Float](repeating: 0, count: at + zero.count)
        for k in 0..<3 {
            for (i, v) in tick.prefix(beat).enumerated() { out[k * beat + i] += tickVolume * v }
        }
        for (i, v) in zero.enumerated() { out[at + i] += v }
        return out.map { min(1, max(-1, $0)) }
    }

    /// The part of a composed count-in that plays when only `beats` of it fit: it starts on that beat.
    public static func slice(_ samples: [Float], rate: Int, beats: Int) -> [Float] {
        let skip = max(0, Int(seconds) - min(Int(seconds), max(0, beats))) * rate
        return skip >= samples.count ? [] : Array(samples[skip...])
    }

    /// 16-bit mono PCM in a WAV, for AVAudioPlayer(data:).
    public static func wav(_ samples: [Float], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for v in samples {
            let x = Int16(clamping: Int((min(1, max(-1, v)) * 32767).rounded()))
            u16(UInt16(bitPattern: x))
        }
        return d
    }
}
