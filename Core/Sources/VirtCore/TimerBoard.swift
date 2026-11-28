import Foundation

/// Everything the app knows about the workout in progress, worked out only from the page's messages (and the lock
/// screen's buttons, which it applies straight away and the page then confirms). Plain values and plain functions,
/// so the tests can run it against a fake clock.
///
/// From it the app reads four things: the alerts to schedule (`alerts`), what the Live Activity shows (`display`),
/// whether to keep the screen awake (`keepAwake`), and when to chime while the app is open (`nextZero`).
public struct TimerBoard: Equatable, Sendable {
    /// After this long with no message and no timer, a workout the page never finished stops keeping the screen on
    /// (the page was closed without saving, say).
    public static let quietLimit: TimeInterval = 45 * 60
    /// iOS holds at most 64 pending notifications per app; this leaves room for the week's workout reminders
    /// (ReminderPlan.daysAhead).
    public static let alertLimit = 56
    /// Rests started by Siri, Shortcuts or a quick action before the page has heard (their ids start with this).
    public static let nativePrefix = "virt-rest:"

    public struct Workout: Equatable, Sendable {
        public var title: String
        public var startedAt: Date
    }

    public struct Countdown: Equatable, Sendable {
        public var id: String
        public var kind: TimerKind
        public var label: String
        public var next: String
        public var startedAt: Date
        /// The end while running; nil while paused or for a stopwatch.
        public var endsAt: Date?
        /// Seconds left while a countdown is paused.
        public var remaining: TimeInterval?
        public var paused: Bool
        /// A hold with no set time: counts up, never ends by itself.
        public var stopwatch: Bool
        /// For a stopwatch: when it was paused, and the paused time so far.
        public var pausedAt: Date?
        public var pausedTotal: TimeInterval
        /// The progress bar's start and its full length.
        public var progressFrom: Date
        public var total: TimeInterval?
        /// Steps known ahead, each with its end measured from this step's end (so a pause or ±15 moves them all).
        public var upcoming: [(step: Step, after: TimeInterval)]

        public static func == (a: Countdown, b: Countdown) -> Bool {
            a.id == b.id && a.kind == b.kind && a.label == b.label && a.next == b.next && a.startedAt == b.startedAt
                && a.endsAt == b.endsAt && a.remaining == b.remaining && a.paused == b.paused && a.stopwatch == b.stopwatch
                && a.pausedAt == b.pausedAt && a.pausedTotal == b.pausedTotal && a.progressFrom == b.progressFrom
                && a.total == b.total && a.upcoming.map(\.step) == b.upcoming.map(\.step) && a.upcoming.map(\.after) == b.upcoming.map(\.after)
        }
    }

    public var workout: Workout?
    public var countdown: Countdown?
    public var lastMessageAt: Date?
    /// When a lock-screen or Dynamic Island button was last pressed (a sign the workout is going, for `midWorkout`).
    public var lastButtonAt: Date?
    /// The last countdown that ran to zero, and when: the next interval phase's bar starts there.
    public var lastEnd: (id: String, at: Date)?
    public var lastSummary: WorkoutSummary?
    /// The set Log set would log (the page's `set.next`, #573). nil when there's none.
    public var nextSet: NextSet?
    /// The set Log set just logged, until the page answers (shown as "Logged" while there's nothing else to show).
    public var justLogged: NextSet?
    /// After the page's rest ran to zero: what it said comes next ("Plank"), kept while there's no timer and no set to
    /// log, so the Live Activity says so instead of ending mid-workout (a circuit's timed exercise is next). Cleared by
    /// the next timer, the next `set.next`, a press, or the workout's end. Not kept across launches.
    public var restOver: (id: String, next: String)?

    public init() {}

    public static func == (a: TimerBoard, b: TimerBoard) -> Bool {
        a.workout == b.workout && a.countdown == b.countdown && a.lastMessageAt == b.lastMessageAt && a.lastButtonAt == b.lastButtonAt
            && a.lastEnd?.id == b.lastEnd?.id && a.lastEnd?.at == b.lastEnd?.at && a.lastSummary == b.lastSummary
            && a.nextSet == b.nextSet && a.justLogged == b.justLogged
            && a.restOver?.id == b.restOver?.id && a.restOver?.next == b.restOver?.next
    }

    // MARK: - The page's messages (the page is the source of truth)

    public mutating func apply(_ message: BridgeMessage, now: Date) {
        // today's plan says nothing about a workout going (the page sends it on every load)
        if case .today = message { return }
        lastMessageAt = now
        switch message {
        case .workoutStart(let title):
            if workout == nil { workout = Workout(title: title, startedAt: now) } else { workout?.title = title }
        case .workoutFinish, .workoutClose:
            if case .workoutFinish(let summary) = message { lastSummary = summary }
            workout = nil
            countdown = nil
            lastEnd = nil
            nextSet = nil
            justLogged = nil
            restOver = nil
        case .timerStart(let s):
            if workout == nil { workout = Workout(title: "Workout", startedAt: now) }
            restOver = nil
            start(s, now: now)
            if let n = s.nextSet { nextSet = n; justLogged = nil }
        case .setNext(let n):
            nextSet = n
            justLogged = nil
            restOver = nil
        case .timerPause(let id, let remaining):
            guard var c = countdown, c.id == id else { return }
            c.paused = true
            if let r = remaining {
                c.stopwatch = false
                c.remaining = max(0, r)
                c.endsAt = nil
            } else if c.pausedAt == nil {
                c.pausedAt = now
            }
            countdown = c
        case .timerResume(let id, let endsAt):
            guard var c = countdown, c.id == id else { return }
            c.paused = false
            if let e = endsAt {
                if let r = c.remaining, let t = c.total { c.progressFrom = e.addingTimeInterval(-max(t, r)) }
                c.endsAt = e
                c.remaining = nil
            } else if let p = c.pausedAt {
                c.pausedTotal += max(0, now.timeIntervalSince(p))
                c.pausedAt = nil
            }
            countdown = c
        case .timerEnd(let id):
            guard let c = countdown, c.id == id else { return }
            lastEnd = (id, min(c.endsAt ?? now, now))
            countdown = nil
            // the page's own rest (not one Virt started for Siri or a press, which just ends)
            restOver = c.kind == .rest && !id.hasPrefix(Self.nativePrefix) ? (id, c.next) : nil
        case .timerCancel(let id):
            guard let c = countdown, c.id == id else { return }
            lastEnd = (id, now)
            countdown = nil
            restOver = nil
        case .today, .setLogged, .unknown:
            break
        }
    }

    // MARK: - A rest started from Siri, Shortcuts or a quick action

    /// Starts a rest right away, so its alert and Live Activity don't wait for the page. When the page starts its own
    /// rest (it got the `rest` command), that one replaces this one.
    public mutating func startNativeRest(seconds: Int, now: Date) {
        let id = Self.nativePrefix + String(Int((now.timeIntervalSince1970 * 1000).rounded()))
        apply(.timerStart(TimerStart(id: id, kind: .rest, label: "Rest", endsAt: now.addingTimeInterval(TimeInterval(seconds)),
                                     startedAt: now, next: "")), now: now)
    }

    /// A rest only Virt knows about ends itself at zero (no page will say so). Returns true if one just ended.
    @discardableResult
    public mutating func expireNative(now: Date) -> Bool {
        guard let c = countdown, c.id.hasPrefix(Self.nativePrefix), !c.paused, let e = c.endsAt, e <= now else { return false }
        apply(.timerEnd(id: c.id), now: now)
        return true
    }

    private mutating func start(_ s: TimerStart, now: Date) {
        let after: [(step: Step, after: TimeInterval)] = s.upcoming.compactMap { u in
            guard let e = u.endsAt, let mine = s.endsAt else { return nil }
            return (u, e.timeIntervalSince(mine))
        }
        if var c = countdown, c.id == s.id {
            // the same countdown with a new end (±15, a changed target): keep where its bar started
            c.label = s.label
            c.next = s.next
            if let e = s.endsAt {
                c.endsAt = e
                c.paused = false
                c.remaining = nil
                c.stopwatch = false
                c.total = e.timeIntervalSince(c.progressFrom)
            }
            if !s.upcoming.isEmpty { c.upcoming = after }
            countdown = c
            return
        }
        let from: Date
        switch s.kind {
        case .rest, .hold: from = s.startedAt
        default:
            // an interval phase: it began when the one before it ended, if that was just now
            if let last = lastEnd, last.at <= now, now.timeIntervalSince(last.at) < 600 { from = last.at } else { from = now }
        }
        countdown = Countdown(
            id: s.id, kind: s.kind, label: s.label, next: s.next, startedAt: s.startedAt, endsAt: s.endsAt,
            remaining: nil, paused: false, stopwatch: s.endsAt == nil && s.kind == .hold, pausedAt: nil, pausedTotal: 0,
            progressFrom: from, total: s.endsAt.map { $0.timeIntervalSince(from) }, upcoming: after)
    }

    // MARK: - The lock screen's buttons, applied straight away

    /// What a button does, before the page hears about it (the page may be asleep while the phone is locked). The
    /// page's own answer replaces this when it comes.
    public mutating func apply(_ command: TimerCommand, now: Date) {
        if command == .log { return logSet(now: now) }
        guard var c = countdown else { return }
        lastButtonAt = now
        switch command {
        case .pause:
            guard !c.paused else { return }
            c.paused = true
            if let e = c.endsAt {
                c.remaining = max(0, e.timeIntervalSince(now))
                c.endsAt = nil
            } else if c.stopwatch {
                c.pausedAt = now
            }
        case .resume:
            guard c.paused else { return }
            c.paused = false
            if let r = c.remaining {
                c.endsAt = now.addingTimeInterval(r)
                c.remaining = nil
                if let t = c.total { c.progressFrom = now.addingTimeInterval(r - t) }
            } else if let p = c.pausedAt {
                c.pausedTotal += max(0, now.timeIntervalSince(p))
                c.pausedAt = nil
            }
        case .add15, .minus15:
            guard !c.stopwatch else { return }
            let by: TimeInterval = command == .add15 ? 15 : -15
            if let e = c.endsAt {
                let moved = max(now, e.addingTimeInterval(by))
                c.total = c.total.map { $0 + moved.timeIntervalSince(e) }
                c.endsAt = moved
            } else if let r = c.remaining {
                let moved = max(0, r + by)
                c.total = c.total.map { $0 + (moved - r) }
                c.remaining = moved
            }
        case .log:
            return
        case .skip:
            if let first = c.upcoming.first, !c.paused {
                // the next phase starts now, for its own length; the rest follow it
                let length = first.after
                let rest = c.upcoming.dropFirst().map { (step: $0.step, after: $0.after - length) }
                let end = now.addingTimeInterval(length)
                c = Countdown(id: first.step.id, kind: first.step.kind, label: first.step.label,
                              next: rest.first?.step.label ?? "Done", startedAt: c.startedAt, endsAt: end, remaining: nil,
                              paused: false, stopwatch: false, pausedAt: nil, pausedTotal: 0, progressFrom: now,
                              total: length, upcoming: Array(rest))
            } else {
                lastEnd = (c.id, now)
                countdown = nil
                return
            }
        }
        countdown = c
    }

    /// Log set (#573), before the page hears (it may be asleep while the phone is locked): the set's rest starts at
    /// once when the plan gives one, and the next set shows as the page says it will be (`then`: in a superset or
    /// circuit, the next exercise of the round) or, from an older page, as it will most likely name it (the same
    /// exercise, one set on), so Log set works again at the rest's zero with the page still asleep. The page logs each tap in
    /// order, from the moment it was tapped, so its own rest lines up with this one. Nothing to log: nothing happens.
    public mutating func logSet(now: Date) {
        guard workout != nil, let n = nextSet else { return }
        lastButtonAt = now
        nextSet = n.following
        justLogged = n
        restOver = nil
        if let r = n.rest {
            let id = Self.nativePrefix + String(Int((now.timeIntervalSince1970 * 1000).rounded()))
            apply(.timerStart(TimerStart(id: id, kind: .rest, label: "Rest", endsAt: now.addingTimeInterval(TimeInterval(r)),
                                         startedAt: now, next: n.after)), now: now)
            lastMessageAt = now
        }
    }

    // MARK: - What the app does with it

    /// The alerts to have scheduled right now: one at the exact end of the running countdown, and one at each known
    /// step after it. Nothing while paused, and nothing for a stopwatch.
    public func alerts(now: Date) -> [PlannedAlert] {
        guard let c = countdown, !c.paused, let end = c.endsAt else { return [] }
        var out: [PlannedAlert] = []
        // each zero's words come from the step that starts there (Tyler, Nov 18): its label and its length
        let first = c.upcoming.first.map { (label: $0.step.label, length: $0.after) }
        if end > now { out.append(Self.alert(id: c.id, kind: c.kind, label: c.label, next: c.next, at: end, length: c.total, starts: first, set: nextSet)) }
        var before = end
        for (i, u) in c.upcoming.enumerated() {
            let at = end.addingTimeInterval(u.after)
            defer { before = at }
            guard at > now else { continue }
            let following = i + 1 < c.upcoming.count ? c.upcoming[i + 1] : nil
            out.append(Self.alert(id: u.step.id, kind: u.step.kind, label: u.step.label, next: following?.step.label ?? "Done", at: at,
                                  length: at.timeIntervalSince(before),
                                  starts: following.map { (label: $0.step.label, length: $0.after - u.after) }))
        }
        return Array(out.prefix(Self.alertLimit))
    }

    /// The first moment a countdown reaches zero from now (for the chime while the app is open).
    public func nextZero(now: Date) -> Date? { alerts(now: now).map(\.fireAt).min() }

    /// What the Live Activity shows: the timer, with the next set under it; between sets (a workout going, no timer),
    /// the next set and Log set; nil when there's neither (the activity ends).
    public func display(now: Date) -> TimerDisplay? {
        guard let c = countdown else {
            let signs = [lastMessageAt, lastButtonAt].compactMap { $0 }
            guard workout != nil, let last = signs.max(), now.timeIntervalSince(last) < Self.quietLimit else { return nil }
            if let n = nextSet {
                var d = TimerDisplay(id: "set:\(n.exercise):\(n.set)", kind: .other, label: n.exercise, next: "")
                d.nextSet = n.label
                d.logButton = "Log set \(n.set)"
                d.betweenSets = true
                d.setExercise = n.exercise
                d.setDetail = n.detail
                return d
            }
            // just logged the last set of an exercise with no rest: "Logged" until the page says what's next
            guard let j = justLogged else {
                // the page's rest ran out with no set to log (a circuit's timed exercise is next): say what's next
                if let r = restOver { return TimerDisplay.restOver(id: r.id, next: r.next) }
                return nil
            }
            var d = TimerDisplay(id: "logged:\(j.exercise):\(j.set)", kind: .other, label: j.exercise, next: "")
            d.betweenSets = true
            d.setExercise = j.exercise
            d.setDetail = "Logged · " + j.detail
            return d
        }
        var d = TimerDisplay(id: c.id, kind: c.kind, label: c.label, next: c.next, paused: c.paused)
        if let n = nextSet {
            d.nextSet = n.label
            d.logButton = "Log set \(n.set)"
            d.setExercise = n.exercise
            d.setDetail = n.detail
        }
        if c.stopwatch {
            d.countsUpFrom = c.startedAt.addingTimeInterval(c.pausedTotal)
            if let p = c.pausedAt, let from = d.countsUpFrom { d.elapsed = max(0, p.timeIntervalSince(from)) }
            return d
        }
        if c.paused {
            d.remaining = c.remaining
            if let r = c.remaining, let t = c.total, t > 0 { d.fraction = min(1, max(0, 1 - r / t)) }
        } else if let e = c.endsAt {
            d.endsAt = e
            d.progressFrom = min(c.progressFrom, e)
            if let first = c.upcoming.first { d.nextEndsAt = e.addingTimeInterval(first.after) }
            if !c.upcoming.isEmpty {
                d.later = c.upcoming.map { LaterStep(id: $0.step.id, kind: $0.step.kind, label: $0.step.label, endsAt: e.addingTimeInterval($0.after)) }
            }
        }
        // past its zero with the page asleep: the step that's running now, from the plan ahead
        return d.current(at: now)
    }

    /// Whether the screen stays awake (Nov 25: only in the workout, for the battery). The page keeps a workout live
    /// while he walks around the other tabs, so a workout going is no longer enough.
    ///
    /// - The page says which screen it's on (`screen` on `today`): awake only on the workout screen, while a countdown
    ///   runs there, or while there's been a sign of the workout within `quietLimit` (a page message, a lock-screen
    ///   button, the page saying it's on the workout screen), so a phone left on the workout screen still sleeps.
    ///   Any other screen: never.
    /// - A page that doesn't say: awake only while a countdown is running (`countdownRunning`).
    public func keepAwake(now: Date, screen: WorkoutScreen? = nil, screenSaidAt: Date? = nil) -> Bool {
        switch screen {
        case nil: return countdownRunning(now: now)
        case .other?: return false
        case .workout?:
            if countdownRunning(now: now) { return true }
            guard let last = [lastMessageAt, lastButtonAt, screenSaidAt].compactMap({ $0 }).max() else { return false }
            let since = now.timeIntervalSince(last)
            return since >= 0 && since < Self.quietLimit
        }
    }

    /// A countdown is running: not paused, and a hold counting up, or a zero still ahead (its own, or one planned
    /// after it). A countdown past its last zero with the page asleep isn't running.
    public func countdownRunning(now: Date) -> Bool {
        guard let c = countdown, !c.paused else { return false }
        if c.stopwatch { return true }
        guard let e = c.endsAt else { return false }
        if e > now { return true }
        return c.upcoming.contains { e.addingTimeInterval($0.after) > now }
    }

    /// True while a workout is going, so coming back to the app doesn't ask for Face ID (`LockPolicy`): a countdown is
    /// running and hasn't reached zero, or a workout or timer is up and there's been a sign of it within `quietLimit`
    /// (a message from the page, a lock-screen button, or a countdown reaching zero). A workout or paused timer left
    /// open for longer than that doesn't count, so the lock still comes.
    public func midWorkout(now: Date) -> Bool {
        if let c = countdown, !c.paused, let e = c.endsAt, e > now { return true }
        guard workout != nil || countdown != nil else { return false }
        var signs = [lastMessageAt, lastButtonAt].compactMap { $0 }
        if let c = countdown, !c.paused, let e = c.endsAt { signs.append(e) }
        guard let last = signs.max() else { return false }
        return now.timeIntervalSince(last) < Self.quietLimit
    }

    /// The title the Live Activity carries: the day's name, such as "Legs A".
    public var title: String { workout?.title ?? "Workout" }

    // MARK: - Alert wording

    /// The alert at one step's zero: one short line about what starts now, nothing about what just ended (Tyler,
    /// Nov 18). Title "Work 5 of 6" with the step's length as the body ("1:00") when it's known; after a rest between
    /// sets, "Go: Chest press, set 2 of 4"; after the last step, "Intervals done".
    /// `starts` is the step that begins at this zero by itself (from `upcoming`); `set` is the next set to log.
    static func alert(id: String, kind: TimerKind, label: String, next: String, at: Date, length: TimeInterval? = nil,
                      starts: (label: String, length: TimeInterval)? = nil, set: NextSet? = nil) -> PlannedAlert {
        let title: String
        var body = ""
        if let s = starts {
            title = short(s.label)
            body = TimerDisplay.clock(s.length)
        } else if next == "Done" {
            title = kind == .work || kind == .intervalRest ? "Intervals done" : "Workout done"
        } else if next == "Logged at the time" {
            title = "\(label) logged"
        } else if kind == .rest {
            title = go(next, set: set)
        } else if !next.isEmpty {
            title = short(next)  // an interval phase without the plan ahead: the page's next label
        } else {
            title = "\(label): time"
        }
        return PlannedAlert(identifier: "virt.timer.\(id)", fireAt: at, title: title, body: body,
                            cue: SoundCue.zero(after: kind), length: length)
    }

    /// "Work · round 5 of 6" or "Work, round 5 of 6" → "Work 5 of 6".
    static func short(_ label: String) -> String {
        var t = label
        for joint in [" · round ", ", round ", " · interval ", ", interval "] { t = t.replacingOccurrences(of: joint, with: " ") }
        return t
    }

    /// After a rest: "Go: Chest press, set 2 of 4" (from the next set the page named), "Go: Chest press, set 2" (from
    /// the rest's own "set 2 of Chest press"), or "Go".
    static func go(_ next: String, set: NextSet?) -> String {
        if let n = set { return "Go: \(n.exercise), set \(n.set) of \(n.of)" }
        if let r = next.range(of: #"^set (\d+) of (.+)$"#, options: .regularExpression), r.lowerBound == next.startIndex {
            let parts = next.dropFirst(4).components(separatedBy: " of ")
            if parts.count >= 2 { return "Go: \(parts.dropFirst().joined(separator: " of ")), set \(parts[0])" }
        }
        return next.isEmpty ? "Go" : "Go: \(next)"
    }
}

// MARK: - Kept on the phone

/// The board, kept on the phone (UserDefaults, `Snapshot.key`, a new key) each time it changes, so a lock-screen
/// button that wakes Virt after iOS ended it (a fresh process, in the background) still knows the workout: Log set
/// logs the right set, and the Live Activity isn't ended for want of a workout.
///
/// Saved-data rule: fields are only ever added, every new one optional. A copy that can't be read is simply no copy.
extension TimerBoard {
    public struct Snapshot: Codable, Equatable, Sendable {
        public static let key = "virt.board"

        public struct Later: Codable, Equatable, Sendable {
            public var id: String
            public var kind: String
            public var label: String
            public var endsAt: Date?
            /// Seconds after the running countdown's end.
            public var after: TimeInterval
        }

        public struct Clock: Codable, Equatable, Sendable {
            public var id: String
            public var kind: String
            public var label: String
            public var next: String
            public var startedAt: Date
            public var endsAt: Date?
            public var remaining: TimeInterval?
            public var paused: Bool
            public var stopwatch: Bool
            public var pausedAt: Date?
            public var pausedTotal: TimeInterval
            public var progressFrom: Date
            public var total: TimeInterval?
            public var upcoming: [Later]?
        }

        public var workoutTitle: String?
        public var workoutStartedAt: Date?
        public var countdown: Clock?
        public var lastMessageAt: Date?
        public var lastButtonAt: Date?
        public var lastEndID: String?
        public var lastEndAt: Date?
        public var nextSet: NextSet?
        public var justLogged: NextSet?

        public func encoded() -> Data? { try? JSONEncoder().encode(self) }
        public static func decode(_ data: Data?) -> Snapshot? { data.flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } }
    }

    public var snapshot: Snapshot {
        var s = Snapshot()
        s.workoutTitle = workout?.title
        s.workoutStartedAt = workout?.startedAt
        if let c = countdown {
            s.countdown = Snapshot.Clock(
                id: c.id, kind: c.kind.rawValue, label: c.label, next: c.next, startedAt: c.startedAt, endsAt: c.endsAt,
                remaining: c.remaining, paused: c.paused, stopwatch: c.stopwatch, pausedAt: c.pausedAt,
                pausedTotal: c.pausedTotal, progressFrom: c.progressFrom, total: c.total,
                upcoming: c.upcoming.map { Snapshot.Later(id: $0.step.id, kind: $0.step.kind.rawValue, label: $0.step.label,
                                                          endsAt: $0.step.endsAt, after: $0.after) })
        }
        s.lastMessageAt = lastMessageAt
        s.lastButtonAt = lastButtonAt
        s.lastEndID = lastEnd?.id
        s.lastEndAt = lastEnd?.at
        s.nextSet = nextSet
        s.justLogged = justLogged
        return s
    }

    /// The board a kept copy describes, if it still matters at `now` (a workout going by `midWorkout`, or a countdown
    /// that hasn't reached zero); otherwise a fresh board, so an old copy never keeps a finished workout alive.
    public static func restored(from s: Snapshot?, now: Date) -> TimerBoard {
        guard let s else { return TimerBoard() }
        var b = TimerBoard()
        if let t = s.workoutTitle, let at = s.workoutStartedAt { b.workout = Workout(title: t, startedAt: at) }
        if let c = s.countdown {
            b.countdown = Countdown(
                id: c.id, kind: TimerKind(c.kind), label: c.label, next: c.next, startedAt: c.startedAt, endsAt: c.endsAt,
                remaining: c.remaining, paused: c.paused, stopwatch: c.stopwatch, pausedAt: c.pausedAt,
                pausedTotal: c.pausedTotal, progressFrom: c.progressFrom, total: c.total,
                upcoming: (c.upcoming ?? []).map { (step: Step(id: $0.id, kind: TimerKind($0.kind), label: $0.label, endsAt: $0.endsAt),
                                                     after: $0.after) })
        }
        b.lastMessageAt = s.lastMessageAt
        b.lastButtonAt = s.lastButtonAt
        if let id = s.lastEndID, let at = s.lastEndAt { b.lastEnd = (id, at) }
        b.nextSet = s.nextSet
        b.justLogged = s.justLogged
        return b.midWorkout(now: now) ? b : TimerBoard()
    }
}
