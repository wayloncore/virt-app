import Foundation

// What studio Training's page sends the app (the website's docs/kinetic/bridge.md, src/lib/training/kinetic.js).
// The page posts plain objects to the `kinetic` message handler; the app turns each into JSON and reads it here.
// Times are epoch milliseconds. Anything this version doesn't know is read as `.unknown`, so a newer page never
// breaks an older app.

public enum TimerKind: String, Codable, Hashable, Sendable {
    case rest, hold, work
    case intervalRest = "interval-rest"
    case other

    init(_ raw: String?) { self = TimerKind(rawValue: raw ?? "") ?? .other }
}

/// One step after the running one, when the page sends the plan ahead (`upcoming`, an optional addition to the
/// bridge; see CLAUDE.md). Its end is as planned, assuming no pause.
public struct Step: Equatable, Hashable, Sendable {
    public var id: String
    public var kind: TimerKind
    public var label: String
    public var endsAt: Date?

    public init(id: String, kind: TimerKind, label: String, endsAt: Date?) {
        self.id = id; self.kind = kind; self.label = label; self.endsAt = endsAt
    }
}

/// The set the lock screen's Log set would log: the open exercise's next set (`set.next`, and `nextSet` on
/// `timer.start`; wayloncore/tyleralocke#573). Weight and reps stay on the phone.
public struct NextSet: Codable, Equatable, Hashable, Sendable {
    public var exercise: String
    public var set: Int
    public var of: Int
    public var weight: Double?
    public var reps: Int?
    /// "Chest press machine · set 2 of 4 · 105 × 10"
    public var label: String
    /// The seconds of the rest that logging it starts, when the plan gives one.
    public var rest: Int?
    /// The sets Log set would log after this one, in order, as the page says them (`then`, added Nov 27; website
    /// docs/kinetic/bridge.md). In a superset or circuit that's the next exercise of the round, never this exercise
    /// again. nil from an older page (then Virt guesses, `following`); empty when the page says nothing can be logged
    /// by a press next (a timed exercise's turn, the end of the exercise or group). Saved-data rule: optional, added.
    public var thenSets: [NextSet]?
    /// What the rest that logging it starts is followed by, in the page's words (`after`: "Seated row machine",
    /// "round 2 of 3", "Plank"). nil from an older page.
    public var afterSaid: String?

    public init(exercise: String, set: Int, of: Int, weight: Double? = nil, reps: Int? = nil, label: String, rest: Int? = nil,
                then: [NextSet]? = nil, after: String? = nil) {
        self.exercise = exercise; self.set = set; self.of = of; self.weight = weight; self.reps = reps
        self.label = label; self.rest = rest; self.thenSets = then; self.afterSaid = after
    }

    /// The label without the exercise's name in front: "set 2 of 4 · 105 × 10".
    public var detail: String {
        let lead = exercise + " · "
        return label.hasPrefix(lead) ? String(label.dropFirst(lead.count)) : label
    }

    /// What the set after this one is called, for a rest Virt starts itself: "set 3 of Chest press machine", or ""
    /// after the last set.
    /// When the page says (`after`, or the first of `then`), its words: in a circuit the next exercise's name.
    public var after: String {
        if let said = afterSaid { return said }
        if let then = thenSets {
            guard let n = then.first else { return "" }
            return n.exercise == exercise ? "set \(n.set) of \(n.exercise)" : n.exercise
        }
        return self.set < of ? "set \(self.set + 1) of \(exercise)" : ""
    }

    /// The set after this one, as the page will most likely name it: the same exercise, the next set, the same weight
    /// and reps (the page carries them forward). nil after the last set (what's next is the page's to say).
    ///
    /// When the page said what follows (`then`), that's it, with the ones after it: Virt never guesses then, so in a
    /// superset or circuit the lock screen names the next exercise of the round, and nothing once the list runs out.
    public var following: NextSet? {
        if let then = thenSets {
            guard var n = then.first else { return nil }
            n.thenSets = Array(then.dropFirst())
            return n
        }
        guard self.set < of else { return nil }
        var n = self
        n.set = set + 1
        n.label = label.replacingOccurrences(of: "set \(set) of \(of)", with: "set \(set + 1) of \(of)")
        return n
    }

    /// Read leniently from the page's object: nil without a label or a set number.
    init?(_ r: RawNextSet?) {
        guard let r, let label = r.label, !label.isEmpty, let n = r.set, n.isFinite, n >= 1 else { return nil }
        let int = { (d: Double?) -> Int? in d.flatMap { $0.isFinite ? Int($0.rounded()) : nil } }
        self.init(exercise: r.exercise ?? "", set: Int(n.rounded()), of: max(int(r.of) ?? Int(n), Int(n.rounded())),
                  weight: r.weight.flatMap { $0.isFinite ? $0 : nil }, reps: int(r.reps), label: label,
                  rest: int(r.rest).flatMap { $0 > 0 ? $0 : nil },
                  then: r.then.map { list in list.compactMap { NextSet($0) } },
                  after: r.after)
    }
}

/// `set.next`'s object as it comes, every field optional.
struct RawNextSet: Decodable {
    var exercise: String?, label: String?
    var set: Double?, of: Double?, weight: Double?, reps: Double?, rest: Double?
    /// `then`: nil when the page doesn't send it; a list (empty for null or anything odd) when it does.
    var then: [RawNextSet]?
    var after: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func text(_ k: Key) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func number(_ k: Key) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil }
        exercise = text(.exercise); label = text(.label)
        set = number(.set); of = number(.of); weight = number(.weight); reps = number(.reps); rest = number(.rest)
        after = text(.after)
        if c.contains(.then) { then = ((try? c.decodeIfPresent([RawNextSet].self, forKey: .then)) ?? nil) ?? [] }
    }
    enum Key: String, CodingKey { case exercise, label, set, of, weight, reps, rest, then, after }
}

public struct TimerStart: Equatable, Sendable {
    public var id: String
    public var kind: TimerKind
    public var label: String
    /// When it reaches zero. nil for a stopwatch hold (counts up) or a countdown that starts paused.
    public var endsAt: Date?
    public var startedAt: Date
    public var next: String
    public var upcoming: [Step]
    /// The set Log set would log after this (an optional addition, #573).
    public var nextSet: NextSet?

    public init(id: String, kind: TimerKind, label: String, endsAt: Date?, startedAt: Date, next: String, upcoming: [Step] = [],
                nextSet: NextSet? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.endsAt = endsAt
        self.startedAt = startedAt; self.next = next; self.upcoming = upcoming; self.nextSet = nextSet
    }
}

/// Counts only, the way the page sends them: no weights, times or notes.
public struct WorkoutSummary: Equatable, Sendable {
    public var mins: Int?
    public var exercises: Int
    public var sets: Int
    public var steps: Int
}

public enum BridgeMessage: Equatable, Sendable {
    case workoutStart(title: String)
    case workoutFinish(WorkoutSummary)
    /// The Active Workout closed without saving (an addition asked for in wayloncore/tyleralocke#518).
    case workoutClose
    /// Also sent with an id that's already running when its end moved (±15, a changed target).
    case timerStart(TimerStart)
    /// `remaining` is nil for a stopwatch hold (nothing to count down to).
    case timerPause(id: String, remaining: TimeInterval?)
    /// `endsAt` is nil for a stopwatch hold.
    case timerResume(id: String, endsAt: Date?)
    case timerCancel(id: String)
    case timerEnd(id: String)
    /// Today's plan, for the widgets, Siri and the reminders (wayloncore/tyleralocke#533). Posted on load and
    /// whenever it changes.
    case today(TodayInfo)
    /// A set was just logged (an optional addition): a light tap and a tiny click. `exercise` is the page's name for it
    /// (optional; a warm-up set's too), so the rest it starts can say whether a different exercise comes next
    /// (`RestWords`).
    case setLogged(exercise: String?)
    /// The set Log set would log now, or nil when there's none (wayloncore/tyleralocke#573).
    case setNext(NextSet?)
    case unknown(type: String)

    /// Reads one message from its JSON. nil if it isn't a message at all (no `type`, or a timer message with no `id`).
    public static func decode(_ data: Data) -> BridgeMessage? {
        guard let type = (try? JSONDecoder().decode(TypeOnly.self, from: data))?.type else { return nil }
        switch type {
        case "today":
            // the fields at the top level, as planned; a nested `today` object reads too. Read on their own, so a
            // field of an unexpected type is skipped instead of losing the message.
            let nested = (try? JSONDecoder().decode(Nested.self, from: data))?.today
            let t = nested ?? (try? JSONDecoder().decode(RawToday.self, from: data)) ?? RawToday()
            return .today(t.info)
        case "set.logged":
            let name = ((try? JSONDecoder().decode(LoggedOnly.self, from: data))?.exercise ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .setLogged(exercise: name.isEmpty ? nil : String(name.prefix(120)))
        case "set.next":
            return .setNext(NextSet((try? JSONDecoder().decode(NextOnly.self, from: data))?.next))
        default:
            break
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let date = { (ms: Double?) in ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
        switch type {
        case "workout.start":
            return .workoutStart(title: raw.title ?? "Workout")
        case "workout.finish":
            let s = raw.summary
            return .workoutFinish(WorkoutSummary(mins: s?.mins.map { Int($0) }, exercises: Int(s?.exercises ?? 0),
                                                 sets: Int(s?.sets ?? 0), steps: Int(s?.steps ?? 0)))
        case "workout.close":
            return .workoutClose
        case "timer.start":
            guard let id = raw.id else { return nil }
            let up = (raw.upcoming ?? []).compactMap { s -> Step? in
                guard let sid = s.id else { return nil }
                return Step(id: sid, kind: TimerKind(s.kind), label: s.label ?? "", endsAt: date(s.endsAt))
            }
            return .timerStart(TimerStart(id: id, kind: TimerKind(raw.kind), label: raw.label ?? "Timer",
                                          endsAt: date(raw.endsAt), startedAt: date(raw.startedAt) ?? Date(),
                                          next: raw.next?.label ?? "", upcoming: up,
                                          nextSet: NextSet((try? JSONDecoder().decode(NextSetOnly.self, from: data))?.nextSet)))
        case "timer.pause":
            guard let id = raw.id else { return nil }
            return .timerPause(id: id, remaining: raw.remaining.map { $0 / 1000 })
        case "timer.resume":
            guard let id = raw.id else { return nil }
            return .timerResume(id: id, endsAt: date(raw.endsAt))
        case "timer.cancel":
            guard let id = raw.id else { return nil }
            return .timerCancel(id: id)
        case "timer.end":
            guard let id = raw.id else { return nil }
            return .timerEnd(id: id)
        default:
            return .unknown(type: type)
        }
    }

    /// Reads a message as WebKit hands it over (a dictionary of plain values).
    /// A guest's "Sign in with Apple" on the try-a-workout page (#806): `{ type: 'signIn', from: 'guest' }`. Not an
    /// Engine message: the app shows its own first screen.
    public static func isGuestSignIn(object: Any) -> Bool {
        guard let d = object as? [String: Any] else { return false }
        return d["type"] as? String == "signIn"
    }

    /// The page's "Account and app settings" row on You (website: docs/kinetic/bridge.md): `{ type: 'settings' }`.
    /// Not an Engine message: the app opens its own settings sheet, where sign out and Delete account are.
    public static func isOpenSettings(object: Any) -> Bool {
        guard let d = object as? [String: Any] else { return false }
        return d["type"] as? String == "settings"
    }

    public static func decode(object: Any) -> BridgeMessage? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return decode(data)
    }

    // Every field optional, so a message with more or fewer fields still reads.
    private struct Raw: Decodable {
        var type: String?
        var id: String?
        var kind: String?
        var label: String?
        var title: String?
        var endsAt: Double?
        var startedAt: Double?
        var remaining: Double?
        var next: Next?
        var summary: Summary?
        var upcoming: [RawStep]?
    }
    private struct Next: Decodable { var label: String? }
    private struct Summary: Decodable { var mins: Double?; var exercises: Double?; var sets: Double?; var steps: Double? }
    private struct RawStep: Decodable { var id: String?; var kind: String?; var label: String?; var endsAt: Double? }
    private struct Nested: Decodable { var today: RawToday? }
    private struct TypeOnly: Decodable { var type: String? }
    // read on their own, so an odd `next` or `nextSet` never loses the message
    private struct NextOnly: Decodable { var next: RawNextSet? }
    private struct LoggedOnly: Decodable { var exercise: String? }
    private struct NextSetOnly: Decodable { var nextSet: RawNextSet? }

    /// `today`, read leniently: a field of the wrong type is skipped instead of losing the whole message.
    private struct RawToday: Decodable {
        var date: String?, title: String?, kind: String?, usualTime: String?, screen: String?
        var done: Bool?
        var minutes: Int?, weekDone: Int?, weekPlanned: Int?, streakWeeks: Int?, streak: Int?
        var streakAtRisk: Bool?, streakAtRiskTomorrow: Bool?, live: Bool?
        var trainingDays: [Int]?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func text(_ k: Key) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
            func number(_ k: Key) -> Int? {
                guard let d = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil, d.isFinite else { return nil }
                return Int(d.rounded())
            }
            date = text(.date); title = text(.title); kind = text(.kind); usualTime = text(.usualTime)
            screen = text(.screen)
            if let b = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? nil { done = b } else { done = number(.done).map { $0 != 0 } }
            minutes = number(.minutes); weekDone = number(.weekDone); weekPlanned = number(.weekPlanned)
            streakWeeks = number(.streakWeeks); streak = number(.streak)
            streakAtRisk = (try? c.decodeIfPresent(Bool.self, forKey: .streakAtRisk)) ?? nil
            streakAtRiskTomorrow = (try? c.decodeIfPresent(Bool.self, forKey: .streakAtRiskTomorrow)) ?? nil
            live = (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? nil
            if let list = (try? c.decodeIfPresent([Double].self, forKey: .trainingDays)) ?? nil {
                trainingDays = list.filter { $0.isFinite }.map { Int($0) }
            }
        }

        enum Key: String, CodingKey {
            case date, title, kind, usualTime, done, minutes, weekDone, weekPlanned, streakWeeks, trainingDays
            case streak, streakAtRisk, streakAtRiskTomorrow, live, screen
        }

        var info: TodayInfo {
            TodayInfo(date: date, title: title, kind: kind, done: done, minutes: minutes, weekDone: weekDone,
                      weekPlanned: weekPlanned, streakWeeks: streakWeeks, trainingDays: trainingDays, usualTime: usualTime,
                      streak: streak, streakAtRisk: streakAtRisk, streakAtRiskTomorrow: streakAtRiskTomorrow, live: live, screen: screen)
        }
    }
}

/// The lock screen's and Dynamic Island's buttons, as the page knows them (`kinetic:command`).
/// `log` is Log set (wayloncore/tyleralocke#573): it logs the next set, with or without a timer running.
public enum TimerCommand: String, CaseIterable, Codable, Sendable {
    case skip, add15, minus15, pause, resume, log

    /// The JavaScript that hands the command to the page. (Log set goes as `PageCommand.log(at:)`, with the moment
    /// it was tapped.)
    public var script: String {
        "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: '\(rawValue)' }));"
    }
}
