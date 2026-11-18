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
    /// Picked from Kenney's free (CC0) sound packs.
    case bell
    /// The first Virt chime, for every zero.
    case classic

    public static let standard: SoundStyle = .chime

    public var name: String {
        switch self {
        case .chime: return "Chime"
        case .bell: return "Bell"
        case .classic: return "Classic"
        }
    }

    public var detail: String {
        switch self {
        case .chime: return "Soft bells, rising for go and falling for rest"
        case .bell: return "Brighter bells and clicks"
        case .classic: return "The first Virt chime"
        }
    }

    /// A stored value read back (an unknown one, from a newer Virt, falls back to the standard style).
    public init(stored: String?) { self = SoundStyle(rawValue: stored ?? "") ?? .standard }

    /// The bundled file for a cue. Classic has one zero sound; its other cues use Chime's.
    public func file(_ cue: SoundCue) -> String {
        if self == .classic {
            return cue == .go || cue == .rest ? "virt-chime.wav" : SoundStyle.chime.file(cue)
        }
        return "virt-\(rawValue)-\(cue.rawValue).caf"
    }
}

/// The 3-2-1 lead-in: a soft tick at 3, 2 and 1 seconds before zero, for countdowns long enough to want one.
public enum LeadIn {
    public static let shortest: TimeInterval = 8

    public static func ticks(zero: Date, now: Date, length: TimeInterval?) -> [Date] {
        if let l = length, l < shortest { return [] }
        return [3.0, 2.0, 1.0].map { zero.addingTimeInterval(-$0) }.filter { $0.timeIntervalSince(now) > 0.05 }
    }
}
