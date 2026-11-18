import AVFoundation
import UIKit
import UserNotifications
import VirtCore

/// Virt's own sounds while the app is open: the soft 3-2-1 ticks, the zero chime (rising when a rest ends, falling
/// when work ends), a tiny click when a set is logged, and a warm finish. All short and quiet, and they mix with his
/// music: plain ambient sound normally; at zero, with music playing, the music ducks for the chime and comes back.
/// The lock-screen alerts use the same zero sounds (`notificationSound`).
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
    private var restoreWork: DispatchWorkItem?
    /// For the test build's status line: the last sound played.
    private(set) var last = "none"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    var style: SoundStyle {
        get { SoundStyle(stored: UserDefaults.standard.string(forKey: Key.style)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.style); players = [:] }
    }

    /// The page's 3-2-1 beeps and these sounds mix with his music and follow the silent switch.
    func setUp() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        for cue in SoundCue.allCases { _ = player(cue, style: style) }
    }

    /// The lock-screen alert's sound for a zero: the same file the app plays.
    func notificationSound(_ cue: SoundCue) -> UNNotificationSound {
        UNNotificationSound(named: UNNotificationSoundName(style.file(cue)))
    }

    /// Plays a cue now (only while the app is open; the alerts sound with it locked).
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
    func preview(_ style: SoundStyle) { play(.go, style: style, force: true) }

    static func volume(_ cue: SoundCue) -> Float {
        switch cue {
        case .leadIn: return 0.55
        case .set: return 0.6
        case .go, .rest: return 0.9
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
