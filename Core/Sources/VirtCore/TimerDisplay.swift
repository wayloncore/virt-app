import Foundation

/// What the Live Activity and the Dynamic Island show: one countdown (or a hold's stopwatch). It's the activity's
/// ContentState, so the system stores it between updates.
///
/// Saved-data rule: fields are only ever added, and every new one is optional, so an activity from the version before
/// still reads. Never rename or remove one.
public struct TimerDisplay: Codable, Hashable, Sendable {
    public var id: String
    public var kind: TimerKind
    /// "Rest", "Plank", "Work · round 2 of 6"
    public var label: String
    /// What comes after: "set 2 of Plank", "Recovery, round 2 of 6", "Done"
    public var next: String
    /// The moment it reaches zero, while it's running. nil while paused, and for a stopwatch.
    public var endsAt: Date?
    /// For a stopwatch hold: it counts up from here (pauses already taken out). nil otherwise.
    public var countsUpFrom: Date?
    /// Where the progress bar starts, while it's running.
    public var progressFrom: Date?
    public var paused: Bool
    /// While a countdown is paused: seconds left, and how far along the bar is (0 to 1).
    public var remaining: TimeInterval?
    public var fraction: Double?
    /// When the step after this one is known ahead (the page's `upcoming`): when it ends.
    public var nextEndsAt: Date?
    /// A paused stopwatch: the time it had run.
    public var elapsed: TimeInterval?

    public init(id: String, kind: TimerKind, label: String, next: String, endsAt: Date? = nil, countsUpFrom: Date? = nil,
                progressFrom: Date? = nil, paused: Bool = false, remaining: TimeInterval? = nil, fraction: Double? = nil,
                nextEndsAt: Date? = nil, elapsed: TimeInterval? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.next = next; self.endsAt = endsAt
        self.countsUpFrom = countsUpFrom; self.progressFrom = progressFrom; self.paused = paused
        self.remaining = remaining; self.fraction = fraction; self.nextEndsAt = nextEndsAt
        self.elapsed = elapsed
    }

    /// A clock face for a number of seconds: 0:45, 1:30, 12:05. Rounds up, so 0:00 shows only at zero.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// One alert the phone should sound at an exact moment (a local notification).
public struct PlannedAlert: Equatable, Sendable {
    /// Stable for one step, so scheduling it again replaces it instead of adding a second.
    public var identifier: String
    public var fireAt: Date
    public var title: String
    public var body: String
}
