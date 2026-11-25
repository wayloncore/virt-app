import ActivityKit
import AppIntents
import SwiftUI
import VirtCore

// Compiled into both the app and the timer extension (the Live Activity).

/// The Live Activity: the day's name stays fixed; the countdown is the content that changes.
struct VirtTimerAttributes: ActivityAttributes {
    typealias ContentState = TimerDisplay
    /// "Legs A", or "Workout". Saved-data rule: add fields only, and make new ones optional.
    var title: String
}

/// A lock-screen or Dynamic Island button, and Control Center's Log set. The system runs it in the app, in the
/// background, which updates the Live Activity at once and hands the command to the page as `kinetic:command`.
///
/// It must work with the phone locked and never ask for Face ID, the way a music app's buttons do (Tyler, Nov 24 and
/// 25; docs/lock-screen-buttons.md has Apple's words for each line here):
/// - `LiveActivityIntent` and `AudioPlaybackIntent`: Apple's two kinds of intent that run in the app's own process
///   from a widget or Live Activity. Apple says to adopt the audio one when the interaction starts or pauses
///   playback; Virt's buttons pause, move and skip the timer whose zero is a sound, and Log set starts a rest that
///   ends in one. It's the kind music apps' lock-screen buttons use.
/// - `authenticationPolicy = .alwaysAllowed`: "allows the app intent to run at any time, including when the device is
///   locked". It's Apple's default, said outright anyway.
/// - It never opens the app (`openAppWhenRun = false`; on iOS 26, `supportedModes = .background`): opening an app
///   from the Lock Screen is what asks for Face ID.
/// - What it runs (Engine.command) asks iOS for nothing and reads only what a locked phone allows after its first
///   unlock (UserDefaults, and keychain copies kept "after first unlock": VirtCore's LockedAccess).
/// - No parameter is left for the system to ask about: the button fills in `command`.
/// VirtCore's LockScreenButtonsTests reads this declaration and fails if any of it goes.
struct TimerCommandIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Timer button"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun: Bool = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Command") var command: String

    init() {}
    init(_ c: TimerCommand) { self.command = c.rawValue }

    func perform() async throws -> some IntentResult {
        if let c = TimerCommand(rawValue: command) { await CommandSink.run(c) }
        return .result()
    }
}

extension Color {
    /// Sampled from the app icon's gold face. Since v3 (#746): the mark and records only, never an action.
    static let virtGold = Color(red: 0xDF / 255, green: 0xC2 / 255, blue: 0x97 / 255)
    /// The app's own dark: v3's graphite (the website's --v3-ink, src/lib/training/v3/tokens.css). Was #0B0A09.
    static let virtBlack = Color(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1B / 255)
    /// v3's one action color on graphite (--v3-red): buttons, the rest ring, links. 5.4:1 on virtBlack.
    static let virtAccent = Color(red: 0xFF / 255, green: 0x4B / 255, blue: 0x3A / 255)
    /// Done (--v3-good on graphite).
    static let virtDone = Color(red: 0x59 / 255, green: 0xCF / 255, blue: 0x8B / 255)
}
