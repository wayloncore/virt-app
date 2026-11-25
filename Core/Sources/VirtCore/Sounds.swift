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
public enum SoundStyle: String, CaseIterable, Sendable {
    /// Clean synthesized bells, made for Virt.
    case chime
    /// Clean tones and clicks picked from Kenney's free (CC0) Interface Sounds.
    case digital
    /// The first Virt chime, for every zero.
    case classic

    public static let standard: SoundStyle = .chime

    public var name: String {
        switch self {
        case .chime: return "Chime"
        case .digital: return "Digital"
        case .classic: return "Classic"
        }
    }

    public var detail: String {
        switch self {
        case .chime: return "A green light when a rest ends, a soft falling bell when work ends"
        case .digital: return "A green light when a rest ends, a falling run of clean tones when work ends"
        case .classic: return "The first Virt chime"
        }
    }

    /// How long before the zero a cue's sound starts, so its main tone lands on the zero: the green light's three short
    /// tones play in the last 1.2 seconds (and they are its lead-in: no 3-2-1 ticks with it). 0 for every other sound.
    public func lead(_ cue: SoundCue) -> TimeInterval { cue == .go && self != .classic ? Self.startLead : 0 }

    /// A stored value read back (an unknown one, from a newer Virt, falls back to the standard style).
    public init(stored: String?) { self = SoundStyle(rawValue: stored ?? "") ?? .standard }

    /// The race-start "go" (Tyler, Nov 24: "a training green-light sound"): three short even tones, then one longer,
    /// higher go tone. It's the sound when a rest ends in Chime and Digital, in the app and on the Lock Screen.
    /// The bells it replaced (`virt-chime-go.caf`, `virt-digital-go.caf`) stay in the app for a rollback.
    public static let startFile = "virt-start-go.caf"
    /// Where the go tone starts in `startFile`: its three short tones come first, so the go tone lands on the zero.
    public static let startLead: TimeInterval = 1.2

    /// The bundled file for a cue. Classic has one zero sound; its other cues use Chime's.
    public func file(_ cue: SoundCue) -> String {
        if cue == .go && self != .classic { return Self.startFile }
        if self == .classic {
            return cue == .go || cue == .rest ? "virt-chime.wav" : SoundStyle.chime.file(cue)
        }
        return "virt-\(rawValue)-\(cue.rawValue).caf"
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
