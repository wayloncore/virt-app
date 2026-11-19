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
    /// The next set to log, when the page says (#573): "Chest press machine · set 2 of 4 · 105 × 10".
    public var nextSet: String?
    /// The Log set button's words ("Log set 2"), when there's a set to log.
    public var logButton: String?
    /// True between sets: no timer running, so it shows the next set and Log set instead of a clock.
    public var betweenSets: Bool?
    /// Between sets: the exercise, and the rest of its line ("set 2 of 4 · 105 × 10").
    public var setExercise: String?
    public var setDetail: String?
    /// The steps after this one, each with its own end (the page's `upcoming`), so the activity can move on to the
    /// step that's running when the page is asleep at a zero (`current(at:)`).
    public var later: [LaterStep]?

    public init(id: String, kind: TimerKind, label: String, next: String, endsAt: Date? = nil, countsUpFrom: Date? = nil,
                progressFrom: Date? = nil, paused: Bool = false, remaining: TimeInterval? = nil, fraction: Double? = nil,
                nextEndsAt: Date? = nil, elapsed: TimeInterval? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.next = next; self.endsAt = endsAt
        self.countsUpFrom = countsUpFrom; self.progressFrom = progressFrom; self.paused = paused
        self.remaining = remaining; self.fraction = fraction; self.nextEndsAt = nextEndsAt
        self.elapsed = elapsed
    }

    /// What to show at `now`: this, until its zero; after it, the step from `later` that's running then (its label, its
    /// countdown, and the one after it as next). After a rest with nothing following, the next set and Log set. The
    /// Live Activity calls it when it draws (at each update, and at the stale date, which is this step's zero), and the
    /// app when it refreshes, so neither waits at 0:00 for the page.
    public func current(at now: Date) -> TimerDisplay {
        guard !paused, betweenSets != true, let e = endsAt, e <= now else { return self }
        let steps = later ?? []
        // the step running now; past the last zero, the last step (at 0:00)
        if let k = steps.firstIndex(where: { $0.endsAt > now }) ?? (steps.isEmpty ? nil : steps.count - 1) {
            let s = steps[k]
            var d = self
            d.id = s.id; d.kind = s.kind; d.label = s.label
            d.endsAt = s.endsAt
            d.progressFrom = k == 0 ? e : steps[k - 1].endsAt
            let rest = Array(steps[(k + 1)...])
            d.next = rest.first?.label ?? "Done"
            d.nextEndsAt = rest.first?.endsAt
            d.later = rest.isEmpty ? nil : rest
            d.remaining = nil; d.fraction = nil
            return d
        }
        if kind == .rest, steps.isEmpty, let words = logButton {
            var d = TimerDisplay(id: "set-after:\(id)", kind: .other, label: setExercise ?? label, next: "")
            d.nextSet = nextSet; d.logButton = words; d.betweenSets = true
            d.setExercise = setExercise; d.setDetail = setDetail
            return d
        }
        return self
    }

    /// A clock face for a number of seconds: 0:45, 1:30, 12:05. Rounds up, so 0:00 shows only at zero.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// A step after the running one, as the Live Activity keeps it (saved-data rule: add optional fields only).
public struct LaterStep: Codable, Hashable, Sendable {
    public var id: String
    public var kind: TimerKind
    public var label: String
    public var endsAt: Date

    public init(id: String, kind: TimerKind, label: String, endsAt: Date) {
        self.id = id; self.kind = kind; self.label = label; self.endsAt = endsAt
    }
}

/// One alert the phone should sound at an exact moment (a local notification).
public struct PlannedAlert: Equatable, Sendable {
    /// Stable for one step, so scheduling it again replaces it instead of adding a second.
    public var identifier: String
    public var fireAt: Date
    public var title: String
    public var body: String
    /// Which zero sound it plays (a rest ending sounds different from work ending).
    public var cue: SoundCue = .go
    /// How long the countdown that ends here runs, when known (the 3-2-1 lead-in skips very short ones).
    public var length: TimeInterval? = nil
}
