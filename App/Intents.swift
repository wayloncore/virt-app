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
