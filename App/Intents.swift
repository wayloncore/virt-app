import AppIntents
import VirtCore

// Siri, Shortcuts and the Action button. Both are App Shortcuts, so they work by voice with no setup:
// "Start my workout in Virt", "Start a rest timer in Virt", "Rest for 90 seconds in Virt".

/// Opens Virt to today's workout and starts it (`startToday` to the page, once Training has loaded).
struct StartWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start my workout"
    static let description = IntentDescription("Opens Virt to today's workout and starts it.")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Engine.shared.startToday()
        return .result()
    }
}

/// Rest lengths Siri understands by name.
enum RestLength: String, AppEnum {
    case s30 = "30", s45 = "45", s60 = "60", s90 = "90", s120 = "120", s180 = "180"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Rest length"
    static let caseDisplayRepresentations: [RestLength: DisplayRepresentation] = [
        .s30: DisplayRepresentation(title: "30 seconds", synonyms: ["30 second", "half a minute"]),
        .s45: DisplayRepresentation(title: "45 seconds", synonyms: ["45 second"]),
        .s60: DisplayRepresentation(title: "60 seconds", synonyms: ["60 second", "1 minute", "a minute", "one minute"]),
        .s90: DisplayRepresentation(title: "90 seconds", synonyms: ["90 second", "a minute and a half"]),
        .s120: DisplayRepresentation(title: "2 minutes", synonyms: ["two minutes", "120 seconds"]),
        .s180: DisplayRepresentation(title: "3 minutes", synonyms: ["three minutes", "180 seconds"]),
    ]

    var seconds: Int { Int(rawValue) ?? RestRequest.standard }
}

/// Starts a rest countdown. It runs in the background (the phone can stay locked): the Live Activity and the alert
/// at zero start right away, and the page gets `rest { seconds }` as soon as Training is open.
struct RestTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start a rest timer"
    static let description = IntentDescription("Starts a rest countdown in Virt, with the timer on the Lock Screen and an alert at zero. 90 seconds unless you choose.")
    /// From the Action button or Siri with the phone locked: runs without an unlock, and never opens the app
    /// (docs/lock-screen-buttons.md).
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Seconds", description: "How long to rest, in seconds (5 to 1800).")
    var seconds: Int?

    @Parameter(title: "Length")
    var length: RestLength?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$seconds)-second rest") { \.$length }
    }

    init() {}

    init(seconds: Int) { self.seconds = seconds }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = RestRequest.seconds(seconds, preset: length?.seconds)
        Engine.shared.startRest(seconds: s)
        return .result(dialog: "Rest \(TimerDisplay.clock(TimeInterval(s))) started.")
    }
}

struct VirtShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWorkoutIntent(), phrases: [
            "Start my workout in \(.applicationName)",
            "Start my \(.applicationName) workout",
            "Start today's workout in \(.applicationName)",
            "\(.applicationName) start my workout",
        ], shortTitle: "Start my workout", systemImageName: "figure.strengthtraining.traditional")
        AppShortcut(intent: RestTimerIntent(), phrases: [
            "Start a rest timer in \(.applicationName)",
            "Start a \(.applicationName) rest timer",
            "Rest in \(.applicationName)",
            "Rest for \(\.$length) in \(.applicationName)",
            "Start a \(\.$length) rest in \(.applicationName)",
        ], shortTitle: "Rest timer", systemImageName: "hourglass")
    }
}

#if DEBUG
/// The test build's check of every intent a lock-screen button, Control Center or the Action button runs while the
/// phone may be locked, read from the real types (VirtCore's LockScreenButtonsTests reads their source on Linux):
/// "ok", or what's wrong. The UI tests read it from the status line.
enum IntentAudit {
    /// The Live Activity's buttons and Control Center's Log set: the kind of intent music apps' buttons use.
    static let buttons: [any AppIntent.Type] = [TimerCommandIntent.self]
    /// Siri and the Action button's rest timer: runs locked too, but isn't a button.
    static let locked: [any AppIntent.Type] = [TimerCommandIntent.self, RestTimerIntent.self]

    static var summary: String {
        var problems: [String] = []
        for t in locked {
            let name = String(describing: t)
            if t.authenticationPolicy != .alwaysAllowed { problems.append("\(name) asks to unlock") }
            if t.openAppWhenRun { problems.append("\(name) opens the app") }
            if !(t is any LiveActivityIntent.Type) { problems.append("\(name) not a LiveActivityIntent") }
        }
        for t in buttons where !(t is any AudioPlaybackIntent.Type) {
            problems.append("\(String(describing: t)) not an AudioPlaybackIntent")
        }
        // every button the Live Activity draws is one of these
        for c in TimerCommand.allCases where TimerCommandIntent(c).command != c.rawValue { problems.append("button \(c.rawValue)") }
        return problems.isEmpty ? "ok" : problems.joined(separator: ",")
    }
}
#endif
