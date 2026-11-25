import Foundation

/// Today's plan, as studio Training's page sends it (the `today` bridge message, wayloncore/tyleralocke#533):
/// `{ date, title, kind: 'workout' | 'rest', done, minutes?, weekDone, weekPlanned, streakWeeks, trainingDays: [0-6],
/// usualTime?: 'HH:MM' }`. Every field is optional, so an older or newer page still reads.
///
/// Virt keeps the last one in the shared keychain (SharedStore) so the widgets and Siri can read it.
/// Saved-data rule: fields are only ever added, every new one optional, never renamed or removed, and a field's type
/// never changes. An older Virt reading a newer copy skips the fields it doesn't know.
public struct TodayInfo: Codable, Equatable, Sendable {
    /// The page's own day, "YYYY-MM-DD" (local time).
    public var date: String?
    /// The day's workout name ("Legs A"), or the rest day's name.
    public var title: String?
    /// "workout" or "rest". Kept as text so a new kind never makes the whole copy unreadable.
    public var kind: String?
    public var done: Bool?
    /// About how long today's workout takes.
    public var minutes: Int?
    public var weekDone: Int?
    public var weekPlanned: Int?
    public var streakWeeks: Int?
    /// The days he trains, 0 (Sunday) to 6 (Saturday), the way JavaScript counts them.
    public var trainingDays: [Int]?
    /// When he usually starts, "HH:MM" (24-hour), from his history.
    public var usualTime: String?
    /// Days in a row, by Training's own rule (added field, optional).
    public var streak: Int?
    /// Today could cost the streak: no rest left this week and today isn't done (added field, optional).
    public var streakAtRisk: Bool?
    /// The same, for tomorrow as things stand now, so the morning nudge can be set the night before (added, optional).
    public var streakAtRiskTomorrow: Bool?
    /// A workout is open on the page right now (added field, optional; the website sends it on `today`). nil from a
    /// page that doesn't say: Virt then falls back to its own 45-minute rule (`TimerBoard.midWorkout`).
    public var live: Bool?
    /// When Virt got it (Virt's own field, not the page's).
    public var receivedAt: Date?

    public init(date: String? = nil, title: String? = nil, kind: String? = nil, done: Bool? = nil, minutes: Int? = nil,
                weekDone: Int? = nil, weekPlanned: Int? = nil, streakWeeks: Int? = nil, trainingDays: [Int]? = nil,
                usualTime: String? = nil, streak: Int? = nil, streakAtRisk: Bool? = nil,
                streakAtRiskTomorrow: Bool? = nil, receivedAt: Date? = nil, live: Bool? = nil) {
        self.date = date; self.title = title; self.kind = kind; self.done = done; self.minutes = minutes
        self.weekDone = weekDone; self.weekPlanned = weekPlanned; self.streakWeeks = streakWeeks
        self.trainingDays = trainingDays; self.usualTime = usualTime; self.receivedAt = receivedAt
        self.streak = streak; self.streakAtRisk = streakAtRisk; self.streakAtRiskTomorrow = streakAtRiskTomorrow
        self.live = live
    }

    /// The same plan, ignoring when it arrived and whether a workout is open (to tell whether the widgets need drawing
    /// again).
    public func samePlan(as other: TodayInfo?) -> Bool {
        guard var o = other else { return false }
        o.receivedAt = receivedAt
        o.live = live
        return o == self
    }

    // MARK: - Stored copy (JSON)

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decodeStored(_ data: Data) -> TodayInfo? { try? JSONDecoder().decode(TodayInfo.self, from: data) }

    // MARK: - Small readers

    /// "18:30" -> (18, 30). nil for anything that isn't a time.
    public static func time(_ s: String?) -> (hour: Int, minute: Int)? {
        guard let s else { return nil }
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// "18:30" -> "6:30 PM"; "07:05" -> "7:05 AM".
    public static func clockLabel(_ s: String?) -> String? {
        guard let t = time(s) else { return nil }
        let h12 = t.hour % 12 == 0 ? 12 : t.hour % 12
        return "\(h12):" + String(format: "%02d", t.minute) + (t.hour < 12 ? " AM" : " PM")
    }

    /// "2026-11-18" -> that day's start in `calendar`'s time zone.
    public static func day(_ s: String?, calendar: Calendar) -> Date? {
        guard let s else { return nil }
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        // a date like 2026-02-31 rolls over; refuse it
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d ? date : nil
    }

    /// 0 (Sunday) to 6 (Saturday), the way the page counts days.
    public static func jsWeekday(_ date: Date, calendar: Calendar) -> Int { calendar.component(.weekday, from: date) - 1 }

    /// The Monday that starts the week a day is in (Training's weeks start on Monday).
    public static func weekStart(_ date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let back = (calendar.component(.weekday, from: day) + 5) % 7  // Sunday 1 -> 6, Monday 2 -> 0
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    static let shortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let longDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// "Mon, Wed and Fri" (Monday first, the way Training's week runs).
    public static func daysLine(_ days: [Int]) -> String {
        let order = [1, 2, 3, 4, 5, 6, 0].filter { days.contains($0) }.map { shortDays[$0] }
        switch order.count {
        case 0: return ""
        case 1: return order[0]
        case 7: return "every day"
        default: return order.dropLast().joined(separator: ", ") + " and " + order.last!
        }
    }

    var validDays: [Int]? { trainingDays.map { Array(Set($0.filter { (0...6).contains($0) })).sorted() } }
}

/// The next workout: today's if it's still to do, or the next training day.
public struct NextUp: Equatable, Sendable {
    /// The start of that day.
    public var day: Date
    /// 0 today, 1 tomorrow, and so on.
    public var inDays: Int
    /// 0 (Sunday) to 6 (Saturday).
    public var weekday: Int
    /// Known only for today.
    public var title: String?
    /// "6:30 PM", when the usual start time is known.
    public var time: String?
    /// The day and the usual time together, when the time is known.
    public var at: Date?
}

/// What the widgets show, worked out from the last `today` the page sent and the clock. When that message is from
/// another day (the app hasn't been opened today), it falls back on the training days: a training day shows as
/// "Training day", not done; the week's count carries over only within the same week.
public struct TodayStatus: Equatable, Sendable {
    public enum Day: String, Equatable, Sendable { case workout, rest, unknown }

    /// False until the page has sent `today` once.
    public var hasData: Bool
    /// True when the page's message is for today.
    public var fresh: Bool
    public var day: Day
    public var title: String
    public var done: Bool
    public var minutes: Int?
    public var weekDone: Int
    public var weekPlanned: Int
    public var streakWeeks: Int?
    public var next: NextUp?

    /// The week ring, 0 to 1.
    public var ring: Double { weekPlanned > 0 ? min(1, max(0, Double(weekDone) / Double(weekPlanned))) : 0 }

    /// "TODAY" (the title says whether it's a rest day).
    public var caption: String { hasData ? "TODAY" : "VIRT" }

    /// "Done", "About 45 min", "Rest and recover"... one short line under the title.
    public var statusLine: String {
        if !hasData { return "Open Virt to load today" }
        if done { return "Done" }
        switch day {
        case .rest: return next.map { "Next: \(TodayStatus.dayName($0, short: true))" } ?? "No workout today"
        case .workout: return minutes.map { "About \($0) min" } ?? (next?.time.map { "Usually \($0)" } ?? "Not started")
        case .unknown: return "Open Virt to load today"
        }
    }

    /// "2 of 4 this week".
    public var weekLine: String { "\(weekDone) of \(weekPlanned) this week" }

    /// "3-week streak", or nil with no streak.
    public var streakLine: String? {
        guard let s = streakWeeks, s > 0 else { return nil }
        return s == 1 ? "1-week streak" : "\(s)-week streak"
    }

    /// "Today", "Tomorrow", "Thu" (or "Thursday").
    public static func dayName(_ n: NextUp, short: Bool) -> String {
        switch n.inDays {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            return (short ? TodayInfo.shortDays : TodayInfo.longDays)[min(6, max(0, n.weekday))]
        }
    }

    /// The three lines of the Lock Screen's "next workout" widget.
    public var nextLines: (caption: String, title: String, detail: String) {
        guard hasData else { return ("VIRT", "Open Virt", "to load today") }
        if let n = next {
            if n.inDays == 0 {
                let cap = n.time.map { "TODAY · \($0)" } ?? "TODAY"
                return (cap, n.title ?? title, minutes.map { "About \($0) min" } ?? weekLine)
            }
            let name = TodayStatus.dayName(n, short: false)
            let detail = [n.time, done ? "done today" : nil].compactMap { $0 }.joined(separator: " · ")
            return ("NEXT WORKOUT", name, detail.isEmpty ? weekLine : detail)
        }
        return ("THIS WEEK", "\(weekDone) of \(weekPlanned) done", streakLine ?? (done ? "Done today" : title))
    }

    /// One line for the Lock Screen's inline widget, above the clock.
    public var inlineLine: String {
        guard hasData else { return "Virt: open to load today" }
        if done { return "Done today · \(weekDone) of \(weekPlanned)" }
        if let n = next, n.inDays == 0 { return [n.title ?? title, n.time].compactMap { $0 }.joined(separator: " · ") }
        if day == .rest { return "Rest day · \(weekDone) of \(weekPlanned)" }
        return "\(title) · \(weekDone) of \(weekPlanned)"
    }

    /// For the widget gallery and the widget picker.
    public static let sample = TodayStatus(hasData: true, fresh: true, day: .workout, title: "Legs A", done: false, minutes: 45,
                                           weekDone: 2, weekPlanned: 4, streakWeeks: 3,
                                           next: NextUp(day: Date(), inDays: 0, weekday: 3, title: "Legs A", time: "6:30 PM", at: nil))
}

extension TodayInfo {
    /// What the widgets show at `now`.
    public func status(now: Date, calendar: Calendar = .current) -> TodayStatus {
        let today = calendar.startOfDay(for: now)
        let theirDay = TodayInfo.day(date, calendar: calendar) ?? receivedAt.map { calendar.startOfDay(for: $0) }
        let fresh = theirDay == today
        let days = validDays
        let todayIsTraining = days?.contains(TodayInfo.jsWeekday(today, calendar: calendar))

        var day: TodayStatus.Day
        var title: String
        var done = false
        var minutes: Int?
        if fresh {
            switch kind {
            case "workout": day = .workout
            case "rest": day = .rest
            default: day = todayIsTraining == true ? .workout : todayIsTraining == false ? .rest : .unknown
            }
            done = self.done ?? false
            minutes = self.minutes.flatMap { $0 > 0 ? $0 : nil }
            title = self.title?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? (day == .rest ? "Rest day" : day == .workout ? "Today's workout" : "Training")
        } else {
            day = todayIsTraining == true ? .workout : todayIsTraining == false ? .rest : .unknown
            title = day == .rest ? "Rest day" : day == .workout ? "Training day" : "Training"
        }

        let thisWeek = TodayInfo.weekStart(today, calendar: calendar)
        let theirWeek = theirDay.map { TodayInfo.weekStart($0, calendar: calendar) }
        let sameWeek = theirWeek == thisWeek
        let lastWeek = theirWeek.flatMap { calendar.date(byAdding: .day, value: 7, to: $0) } == thisWeek
        let planned = max(0, (sameWeek ? weekPlanned : nil) ?? days?.count ?? weekPlanned ?? 0)
        let weekDone = max(0, sameWeek ? (self.weekDone ?? 0) : 0)
        let streak = (sameWeek || lastWeek) ? streakWeeks : nil

        // the next workout: today's if it's still to do, else the next training day within a week
        var next: NextUp?
        let time = TodayInfo.clockLabel(usualTime)
        let at = { (d: Date) -> Date? in
            guard let t = TodayInfo.time(self.usualTime) else { return nil }
            return calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: d)
        }
        if day == .workout && !done {
            next = NextUp(day: today, inDays: 0, weekday: TodayInfo.jsWeekday(today, calendar: calendar),
                          title: fresh ? title : nil, time: time, at: at(today))
        } else if let days, !days.isEmpty {
            for n in 1...7 {
                guard let d = calendar.date(byAdding: .day, value: n, to: today) else { break }
                let wd = TodayInfo.jsWeekday(d, calendar: calendar)
                if days.contains(wd) {
                    next = NextUp(day: d, inDays: n, weekday: wd, title: nil, time: time, at: at(d))
                    break
                }
            }
        }

        return TodayStatus(hasData: true, fresh: fresh, day: day, title: title, done: done, minutes: minutes,
                           weekDone: weekDone, weekPlanned: planned, streakWeeks: streak, next: next)
    }
}

extension Optional where Wrapped == TodayInfo {
    /// No message yet: the widgets ask him to open Virt.
    public func status(now: Date, calendar: Calendar = .current) -> TodayStatus {
        if let info = self { return info.status(now: now, calendar: calendar) }
        return TodayStatus(hasData: false, fresh: false, day: .unknown, title: "Training", done: false, minutes: nil,
                           weekDone: 0, weekPlanned: 0, streakWeeks: nil, next: nil)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Workout reminders

/// One "Today: Legs A" nudge at his usual start time.
public struct PlannedReminder: Equatable, Sendable {
    /// One per day ("virt.reminder.2026-11-18"), so scheduling again replaces it.
    public var identifier: String
    public var fireAt: Date
    public var title: String
    public var body: String
}

/// The reminders to have scheduled: one on each training day at the usual time, for the next week. Today's is left
/// out once the workout is done (or while one is going); "Move it" pushes today's an hour later. Nothing without
/// both the training days and the usual time.
public enum ReminderPlan {
    /// Days ahead (today included). Timer alerts keep the rest of iOS's 64 pending notifications.
    public static let daysAhead = 7
    /// What "Move it" adds.
    public static let moveBy: TimeInterval = 60 * 60
    public static let prefix = "virt.reminder."

    public static func plan(_ info: TodayInfo?, now: Date, calendar: Calendar = .current, movedTo: Date? = nil,
                            workoutGoing: Bool = false) -> [PlannedReminder] {
        guard let info, let t = TodayInfo.time(info.usualTime), let days = info.validDays, !days.isEmpty else { return [] }
        let status = info.status(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        var out: [PlannedReminder] = []
        for n in 0..<daysAhead {
            guard let d = calendar.date(byAdding: .day, value: n, to: today),
                  var at = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: d) else { continue }
            let isToday = n == 0
            if isToday {
                guard status.day == .workout, !status.done, !workoutGoing else { continue }
                if let m = movedTo, calendar.isDate(m, inSameDayAs: d), m > at { at = m }
            } else if !days.contains(TodayInfo.jsWeekday(d, calendar: calendar)) {
                continue
            }
            guard at > now else { continue }
            let title: String
            let body: String
            if isToday && status.fresh {
                title = "Today: \(status.title)"
                body = status.minutes.map { "About \($0) min. Tap to open it." } ?? "Tap to open it in Virt."
            } else {
                title = "Today: training day"
                body = "Your workout's ready in Virt."
            }
            out.append(PlannedReminder(identifier: prefix + dayKey(d, calendar: calendar), fireAt: at, title: title, body: body))
        }
        return out
    }

    /// Where "Move it" puts today's reminder: an hour after it was due, or an hour from now if that's later.
    public static func moved(from due: Date?, now: Date) -> Date {
        max(now, due ?? now).addingTimeInterval(moveBy)
    }

    // MARK: - The streak's morning nudge (Tyler, Nov 23)

    /// When the streak nudge comes: in the morning, never right before the day ends.
    public static let streakHour = 9
    public static let streakPrefix = "virt.reminder.streak."

    /// One quiet nudge at 9:00 on a day that could cost the streak: today if the page says today is at risk and it
    /// isn't done, and tomorrow if the page says tomorrow would be (set the night before; it stays in place the
    /// next morning until the page says otherwise). Nothing at a streak of zero, and nothing from an older copy.
    public static func streakPlan(_ info: TodayInfo?, now: Date, calendar: Calendar = .current,
                                  workoutGoing: Bool = false) -> [PlannedReminder] {
        guard let info, let n = info.streak, n > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        guard let theirs = TodayInfo.day(info.date, calendar: calendar) ?? info.receivedAt.map({ calendar.startOfDay(for: $0) }),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let theirNext = calendar.date(byAdding: .day, value: 1, to: theirs) else { return [] }
        var out: [PlannedReminder] = []
        func add(_ day: Date) {
            guard let at = calendar.date(bySettingHour: streakHour, minute: 0, second: 0, of: day), at > now else { return }
            out.append(PlannedReminder(identifier: streakPrefix + dayKey(day, calendar: calendar), fireAt: at,
                                       title: "Keep your \(n)-day streak", body: "A workout today keeps it going."))
        }
        if theirs == today {
            if info.streakAtRisk == true, info.done != true, !workoutGoing { add(today) }
            // one at a time (iOS keeps 64 pending, and the timer's alerts and the week's reminders use 63)
            if out.isEmpty, info.streakAtRiskTomorrow == true { add(tomorrow) }
        } else if theirNext == today, info.streakAtRiskTomorrow == true {
            add(today)   // last night's copy: this morning's nudge stays until the page opens
        }
        return out
    }

    static func dayKey(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
