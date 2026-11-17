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

/// A lock-screen or Dynamic Island button. The system runs it in the app (a LiveActivityIntent), which updates the
/// Live Activity at once and hands the command to the page as `kinetic:command`.
struct TimerCommandIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Timer button"
    static let isDiscoverable = false

    @Parameter(title: "Command") var command: String

    init() {}
    init(_ c: TimerCommand) { self.command = c.rawValue }

    func perform() async throws -> some IntentResult {
        if let c = TimerCommand(rawValue: command) { await CommandSink.run(c) }
        return .result()
    }
}

extension Color {
    /// Sampled from the app icon's gold face, and its black.
    static let virtGold = Color(red: 0xDF / 255, green: 0xC2 / 255, blue: 0x97 / 255)
    static let virtBlack = Color(red: 0x0B / 255, green: 0x0A / 255, blue: 0x09 / 255)
}
