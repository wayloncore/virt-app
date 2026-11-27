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
    /// Clean tones and clicks picked from Kenney's free (CC0) Interface Sounds; work ends with a rising trill.
    case digital
    // The tone styles (Tyler, Nov 27): one loud tone, synthesized for Virt (`scripts/sounds.py tones`), for both zeros.
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
        case .digital, .glass, .sonar, .synthRise, .watchBeeps, .marimba, .ringBell, .buzzerHorn: return .clean
        case .arcade, .levelUp, .coinPickup, .victory, .bounce, .questJingle: return .playful
        }
    }

    /// The styles under one title, in display order.
    public static func styles(in group: Group) -> [SoundStyle] { allCases.filter { $0.group == group } }

    /// A tone style: its one tone is the zero sound for both zeros, and its other cues are Chime's.
    public var isTone: Bool { group != .classic && self != .digital }

    public var detail: String {
        switch self {
        case .chime: return "A green light when a rest ends, a soft falling bell when work ends"
        case .digital: return "A green light when a rest ends, a rising trill when work ends"
        case .classic: return "The first Virt chime"
        default: return "The same tone at both zeros, after a 3-2-1"
        }
    }

    /// How long before the zero a cue's sound starts, so its main tone lands on the zero: the green light's three short
    /// tones play in the last 1.2 seconds (and they are its lead-in: no 3-2-1 ticks with it). 0 for every other sound.
    public func lead(_ cue: SoundCue) -> TimeInterval { file(cue) == Self.startFile ? Self.startLead : 0 }

    /// A stored value read back (an unknown one, from a newer Virt, falls back to the standard style).
    public init(stored: String?) { self = SoundStyle(rawValue: stored ?? "") ?? .standard }

    /// The race-start "go" (Tyler, Nov 24: "a training green-light sound"): three short even tones, then one longer,
    /// higher go tone. It's the sound when a rest ends in Chime and Digital, in the app and on the Lock Screen.
    /// The bells it replaced (`virt-chime-go.caf`, `virt-digital-go.caf`) stay in the app for a rollback.
    public static let startFile = "virt-start-go.caf"
    /// Where the go tone starts in `startFile`: its three short tones come first, so the go tone lands on the zero.
    public static let startLead: TimeInterval = 1.2

    /// The bundled file for a cue. Classic has one zero sound and a tone style one tone; their other cues use Chime's.
    /// Digital's work-ends sound is the rising trill (Tyler, Nov 27); its old falling run (`virt-digital-rest.caf`)
    /// stays in the app for a rollback.
    public func file(_ cue: SoundCue) -> String {
        let zero = cue == .go || cue == .rest
        switch self {
        case .classic:
            return zero ? "virt-chime.wav" : SoundStyle.chime.file(cue)
        case .chime, .digital:
            if cue == .go { return Self.startFile }
            if self == .digital && cue == .rest { return "virt-digital-up.caf" }
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

/// The 3-2-1 lead-in: a soft tick at 3, 2 and 1 seconds before zero, for countdowns long enough to want one.
public enum LeadIn {
    public static let shortest: TimeInterval = 8

    /// `lead`: the zero sound's own lead-in (SoundStyle.lead); with one, no ticks (they'd clash with its tones).
    public static func ticks(zero: Date, now: Date, length: TimeInterval?, lead: TimeInterval = 0) -> [Date] {
        if lead > 0 { return [] }
        if let l = length, l < shortest { return [] }
        return [3.0, 2.0, 1.0].map { zero.addingTimeInterval(-$0) }.filter { $0.timeIntervalSince(now) > 0.05 }
    }
}
