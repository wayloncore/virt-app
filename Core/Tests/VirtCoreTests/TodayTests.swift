import XCTest
@testable import VirtCore

/// The `today` message, what the widgets show from it (fresh, a day old, a week old), and the workout reminders.
final class TodayTests: XCTestCase {
    /// A fixed calendar (New York's standard time), so the tests don't depend on the machine's time zone.
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        return c
    }()
    /// Wednesday, Nov 18 2026 at noon.
    let wedNoon = Date(timeIntervalSince1970: 1_795_021_200)
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    /// Mon, Wed, Fri at 6:30 PM.
    func wed(_ change: (inout TodayInfo) -> Void = { _ in }) -> TodayInfo {
        var t = TodayInfo(date: "2026-11-18", title: "Legs A", kind: "workout", done: false, minutes: 45, weekDone: 1,
                          weekPlanned: 3, streakWeeks: 3, trainingDays: [1, 3, 5], usualTime: "18:30")
        change(&t)
        return t
    }

    // MARK: - The message

    func testReadsTheMessageAsPlanned() {
        let json = #"{"type":"today","date":"2026-11-18","title":"Legs A","kind":"workout","done":false,"minutes":45,"weekDone":1,"weekPlanned":3,"streakWeeks":3,"trainingDays":[1,3,5],"usualTime":"18:30","later":"ignored"}"#
        XCTAssertEqual(BridgeMessage.decode(Data(json.utf8)), .today(wed()))
    }

    func testEveryFieldIsOptionalAndWrongTypesAreSkipped() {
        XCTAssertEqual(BridgeMessage.decode(Data(#"{"type":"today"}"#.utf8)), .today(TodayInfo()))
        let odd = #"{"type":"today","title":7,"done":1,"minutes":"lots","weekDone":2.0,"trainingDays":[1,"x"]}"#
        XCTAssertEqual(BridgeMessage.decode(Data(odd.utf8)), .today(TodayInfo(done: true, weekDone: 2)))
        let nested = #"{"type":"today","today":{"title":"Push B","kind":"workout"}}"#
        XCTAssertEqual(BridgeMessage.decode(Data(nested.utf8)), .today(TodayInfo(title: "Push B", kind: "workout")))
    }

    func testFromWebKitObject() {
        let obj: [String: Any] = ["type": "today", "title": "Legs A", "done": true, "trainingDays": [1, 3]]
        XCTAssertEqual(BridgeMessage.decode(object: obj), .today(TodayInfo(title: "Legs A", done: true, trainingDays: [1, 3])))
        XCTAssertEqual(BridgeMessage.decode(object: ["type": "set.logged", "exercise": "Squat"]), .setLogged)
    }

    func testStoredCopyRoundTripsAndOlderCopiesRead() {
        var t = wed()
        t.receivedAt = wedNoon
        XCTAssertEqual(t.encoded().flatMap(TodayInfo.decodeStored), t)
        // a copy with fewer fields (an older Virt) and one with more (a newer one): both read
        XCTAssertEqual(TodayInfo.decodeStored(Data(#"{"title":"Legs A"}"#.utf8)), TodayInfo(title: "Legs A"))
        XCTAssertEqual(TodayInfo.decodeStored(Data(#"{"title":"Legs A","moodRing":true}"#.utf8))?.title, "Legs A")
        XCTAssertTrue(t.samePlan(as: wed()), "only the arrival time differs")
        XCTAssertFalse(t.samePlan(as: wed { $0.done = true }))
        XCTAssertFalse(t.samePlan(as: nil))
    }

    func testSmallReaders() {
        XCTAssertEqual(TodayInfo.clockLabel("18:30"), "6:30 PM")
        XCTAssertEqual(TodayInfo.clockLabel("07:05"), "7:05 AM")
        XCTAssertEqual(TodayInfo.clockLabel("00:00"), "12:00 AM")
        XCTAssertEqual(TodayInfo.clockLabel("12:15"), "12:15 PM")
        XCTAssertNil(TodayInfo.clockLabel("25:00"))
        XCTAssertNil(TodayInfo.clockLabel("soon"))
        XCTAssertNil(TodayInfo.day("2026-02-31", calendar: cal))
        XCTAssertEqual(TodayInfo.day("2026-11-18", calendar: cal), at(18, 0))
        XCTAssertEqual(TodayInfo.weekStart(wedNoon, calendar: cal), at(16, 0), "weeks start Monday")
        XCTAssertEqual(TodayInfo.weekStart(at(22, 20), calendar: cal), at(16, 0), "Sunday is the week's last day")
        XCTAssertEqual(TodayInfo.daysLine([5, 1, 3]), "Mon, Wed and Fri")
        XCTAssertEqual(TodayInfo.daysLine([0, 6]), "Sat and Sun")
        XCTAssertEqual(TodayInfo.daysLine([0, 1, 2, 3, 4, 5, 6]), "every day")
    }

    // MARK: - What the widgets show

    func testNoMessageYet() {
        let s = Optional<TodayInfo>.none.status(now: wedNoon, calendar: cal)
        XCTAssertFalse(s.hasData)
        XCTAssertEqual(s.statusLine, "Open Virt to load today")
        XCTAssertEqual(s.nextLines.title, "Open Virt")
        XCTAssertEqual(s.ring, 0)
    }

    func testAFreshWorkoutDay() {
        let s = wed().status(now: wedNoon, calendar: cal)
        XCTAssertTrue(s.fresh)
        XCTAssertEqual(s.day, .workout)
        XCTAssertEqual(s.title, "Legs A")
        XCTAssertEqual(s.caption, "TODAY")
        XCTAssertEqual(s.statusLine, "About 45 min")
        XCTAssertEqual(s.weekLine, "1 of 3 this week")
        XCTAssertEqual(s.streakLine, "3-week streak")
        XCTAssertEqual(s.ring, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(s.next?.inDays, 0)
        XCTAssertEqual(s.next?.at, at(18, 18, 30))
        XCTAssertEqual(s.nextLines.caption, "TODAY · 6:30 PM")
        XCTAssertEqual(s.nextLines.title, "Legs A")
        XCTAssertEqual(s.inlineLine, "Legs A · 6:30 PM")
    }

    func testDoneTodayPointsAtTheNextTrainingDay() {
        let s = wed { $0.done = true; $0.weekDone = 2 }.status(now: wedNoon, calendar: cal)
        XCTAssertEqual(s.statusLine, "Done")
        XCTAssertEqual(s.next?.inDays, 2)
        XCTAssertEqual(s.next?.weekday, 5)
        XCTAssertEqual(s.nextLines.caption, "NEXT WORKOUT")
        XCTAssertEqual(s.nextLines.title, "Friday")
        XCTAssertEqual(s.nextLines.detail, "6:30 PM · done today")
        XCTAssertEqual(s.inlineLine, "Done today · 2 of 3")
    }

    func testARestDay() {
        let s = wed { $0.kind = "rest"; $0.title = "Rest day"; $0.minutes = nil }.status(now: wedNoon, calendar: cal)
        XCTAssertEqual(s.day, .rest)
        XCTAssertEqual(s.caption, "TODAY")
        XCTAssertEqual(s.title, "Rest day")
        XCTAssertEqual(s.statusLine, "Next: Fri")
        XCTAssertEqual(s.inlineLine, "Rest day · 1 of 3")
    }

    func testThursdayWithWednesdaysMessage() {
        // the app wasn't opened Thursday: Thursday isn't a training day, Friday is
        let thu = at(19, 9)
        let s = wed().status(now: thu, calendar: cal)
        XCTAssertFalse(s.fresh)
        XCTAssertEqual(s.day, .rest)
        XCTAssertEqual(s.title, "Rest day")
        XCTAssertEqual(s.weekDone, 1, "same week: the count carries over")
        XCTAssertEqual(s.streakWeeks, 3)
        XCTAssertEqual(s.next?.inDays, 1)
        XCTAssertEqual(s.nextLines.title, "Tomorrow")
        // Friday: a training day, not known to be done
        let f = wed().status(now: at(20, 9), calendar: cal)
        XCTAssertEqual(f.day, .workout)
        XCTAssertEqual(f.title, "Training day")
        XCTAssertFalse(f.done)
        XCTAssertNil(f.minutes)
        XCTAssertEqual(f.next?.title, nil, "only today's title is ever known")
        XCTAssertEqual(f.nextLines.title, "Training day")
    }

    func testANewWeekStartsAtZero() {
        let mon = at(23, 8)
        let s = wed { $0.done = true; $0.weekDone = 3 }.status(now: mon, calendar: cal)
        XCTAssertEqual(s.weekDone, 0)
        XCTAssertEqual(s.weekPlanned, 3, "from the training days")
        XCTAssertEqual(s.streakWeeks, 3, "last week's streak still shows")
        let later = wed().status(now: at(30, 8), calendar: cal)
        XCTAssertNil(later.streakWeeks, "two weeks on, the streak is unknown")
    }

    func testNoDateUsesWhenItArrived() {
        let s = TodayInfo(title: "Legs A", kind: "workout", receivedAt: at(18, 7)).status(now: wedNoon, calendar: cal)
        XCTAssertTrue(s.fresh)
        XCTAssertEqual(s.title, "Legs A")
        XCTAssertNil(s.next?.time, "no usual time")
        XCTAssertEqual(s.nextLines.caption, "TODAY")
    }

    // MARK: - Reminders

    func testRemindersOnTrainingDaysAtTheUsualTime() {
        let r = ReminderPlan.plan(wed(), now: wedNoon, calendar: cal)
        XCTAssertEqual(r.map(\.fireAt), [at(18, 18, 30), at(20, 18, 30), at(23, 18, 30)], "Wed, Fri, Mon")
        XCTAssertEqual(r.first?.identifier, "virt.reminder.2026-11-18")
        XCTAssertEqual(r.first?.title, "Today: Legs A")
        XCTAssertEqual(r.first?.body, "About 45 min. Tap to open it.")
        XCTAssertEqual(r.last?.title, "Today: training day")
    }

    func testTodaysIsSkippedOnceDoneOrWhileGoingOrPast() {
        XCTAssertEqual(ReminderPlan.plan(wed { $0.done = true }, now: wedNoon, calendar: cal).first?.fireAt, at(20, 18, 30))
        XCTAssertEqual(ReminderPlan.plan(wed(), now: wedNoon, calendar: cal, workoutGoing: true).first?.fireAt, at(20, 18, 30))
        XCTAssertEqual(ReminderPlan.plan(wed(), now: at(18, 19), calendar: cal).first?.fireAt, at(20, 18, 30))
        XCTAssertEqual(ReminderPlan.plan(wed { $0.kind = "rest" }, now: wedNoon, calendar: cal).first?.fireAt, at(20, 18, 30))
    }

    func testMoveItPushesTodaysAnHour() {
        let moved = ReminderPlan.moved(from: at(18, 18, 30), now: at(18, 18, 31))
        XCTAssertEqual(moved, at(18, 19, 31))
        XCTAssertEqual(ReminderPlan.moved(from: at(18, 18, 30), now: at(18, 10)), at(18, 19, 30))
        let r = ReminderPlan.plan(wed(), now: at(18, 18, 31), calendar: cal, movedTo: moved)
        XCTAssertEqual(r.first?.fireAt, moved)
        XCTAssertEqual(r.first?.identifier, "virt.reminder.2026-11-18")
        let tomorrow = ReminderPlan.plan(wed(), now: at(19, 8), calendar: cal, movedTo: moved)
        XCTAssertEqual(tomorrow.first?.fireAt, at(20, 18, 30), "yesterday's move doesn't carry over")
    }

    func testNothingWithoutDaysOrTime() {
        XCTAssertTrue(ReminderPlan.plan(nil, now: wedNoon, calendar: cal).isEmpty)
        XCTAssertTrue(ReminderPlan.plan(wed { $0.usualTime = nil }, now: wedNoon, calendar: cal).isEmpty)
        XCTAssertTrue(ReminderPlan.plan(wed { $0.trainingDays = [] }, now: wedNoon, calendar: cal).isEmpty)
        XCTAssertTrue(ReminderPlan.plan(wed { $0.trainingDays = [9] }, now: wedNoon, calendar: cal).isEmpty)
    }

    func testTheStreakNudgeComesInTheMorning() {
        let early = at(18, 7)
        let risk = wed { $0.streak = 12; $0.streakAtRisk = true }
        let r = ReminderPlan.streakPlan(risk, now: early, calendar: cal)
        XCTAssertEqual(r.map(\.fireAt), [at(18, 9)], "9:00, not right before the day ends")
        XCTAssertEqual(r.first?.identifier, "virt.reminder.streak.2026-11-18")
        XCTAssertEqual(r.first?.title, "Keep your 12-day streak")
        XCTAssertTrue(ReminderPlan.streakPlan(risk, now: wedNoon, calendar: cal).isEmpty, "past 9: nothing late in the day")
        XCTAssertTrue(ReminderPlan.streakPlan(wed { $0.streak = 12; $0.streakAtRisk = true; $0.done = true }, now: early, calendar: cal).isEmpty)
        XCTAssertTrue(ReminderPlan.streakPlan(risk, now: early, calendar: cal, workoutGoing: true).isEmpty)
        XCTAssertTrue(ReminderPlan.streakPlan(wed { $0.streak = 0; $0.streakAtRisk = true }, now: early, calendar: cal).isEmpty, "no streak, no nudge")
        XCTAssertTrue(ReminderPlan.streakPlan(wed { $0.streak = 12 }, now: early, calendar: cal).isEmpty, "rest left this week: nothing")
        XCTAssertTrue(ReminderPlan.streakPlan(wed(), now: early, calendar: cal).isEmpty, "an older page that doesn't say: nothing")
    }

    func testTheStreakNudgeIsSetTheNightBefore() {
        let tonight = wed { $0.streak = 5; $0.done = true; $0.streakAtRiskTomorrow = true }
        XCTAssertEqual(ReminderPlan.streakPlan(tonight, now: at(18, 21), calendar: cal).map(\.fireAt), [at(19, 9)])
        XCTAssertEqual(ReminderPlan.streakPlan(tonight, now: at(19, 7), calendar: cal).map(\.fireAt), [at(19, 9)],
                       "the next morning, before the page has opened, it's still there")
        XCTAssertTrue(ReminderPlan.streakPlan(tonight, now: at(20, 7), calendar: cal).isEmpty, "two days on: too old to trust")
    }

    func testRemindersAndTimerAlertsFitIOSsLimit() {
        XCTAssertLessThanOrEqual(TimerBoard.alertLimit + ReminderPlan.daysAhead + 2, 64)
    }
}
