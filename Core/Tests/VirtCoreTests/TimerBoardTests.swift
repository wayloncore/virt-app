import XCTest
@testable import VirtCore

/// The timer math against a fake clock: the bridge's own example (a 45 s rest, +15 from the lock screen, then a plank
/// hold), pauses, a stopwatch hold, interval phases with and without the plan ahead, and the screen staying on.
final class TimerBoardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_763_373_600)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }

    func rest(_ start: TimeInterval, _ len: TimeInterval, next: String = "set 2 of Plank") -> BridgeMessage {
        .timerStart(TimerStart(id: "rest:\(start)", kind: .rest, label: "Rest", endsAt: s(start + len), startedAt: s(start), next: next))
    }

    func testTheBridgeExample() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Legs A"), now: s(0))
        b.apply(rest(0, 45), now: s(0))
        XCTAssertEqual(b.alerts(now: s(0)), [PlannedAlert(identifier: "virt.timer.rest:0.0", fireAt: s(45), title: "Rest is over", body: "Up next: set 2 of Plank", cue: .go, length: 45)])
        XCTAssertEqual(b.nextZero(now: s(1)), s(45))
        XCTAssertEqual(b.display(now: s(0))?.endsAt, s(45))
        XCTAssertEqual(b.display(now: s(0))?.progressFrom, s(0))
        XCTAssertTrue(b.keepAwake(now: s(0)))

        // +15 on the lock screen: the app moves the end right away...
        b.apply(.add15, now: s(10))
        XCTAssertEqual(b.alerts(now: s(10)).map(\.fireAt), [s(60)])
        // ...and the page confirms with the same id and the new end
        b.apply(rest(0, 60), now: s(11))
        XCTAssertEqual(b.alerts(now: s(11)).map(\.fireAt), [s(60)])
        XCTAssertEqual(b.display(now: s(11))?.progressFrom, s(0), "the bar keeps its start")

        // zero: the page ends the rest and starts the timed hold the same moment
        b.apply(.timerEnd(id: "rest:0.0"), now: s(60))
        XCTAssertNil(b.display(now: s(60)))
        b.apply(.timerStart(TimerStart(id: "hold:60", kind: .hold, label: "Plank", endsAt: s(105), startedAt: s(60), next: "Logged at the time")), now: s(60))
        XCTAssertEqual(b.alerts(now: s(60)), [PlannedAlert(identifier: "virt.timer.hold:60", fireAt: s(105), title: "Plank: time", body: "Set logged", cue: .rest, length: 45)])
        b.apply(.timerEnd(id: "hold:60"), now: s(105))
        XCTAssertTrue(b.alerts(now: s(105)).isEmpty)
        XCTAssertTrue(b.keepAwake(now: s(105)), "the workout is still going")

        b.apply(.workoutFinish(WorkoutSummary(mins: 2, exercises: 1, sets: 2, steps: 0)), now: s(120))
        XCTAssertFalse(b.keepAwake(now: s(120)))
        XCTAssertNil(b.workout)
    }

    func testPausedRestFromThePage() {
        var b = TimerBoard()
        b.apply(rest(0, 45), now: s(0))
        b.apply(.timerPause(id: "rest:0.0", remaining: 35), now: s(10))
        XCTAssertTrue(b.alerts(now: s(10)).isEmpty, "no alert while paused")
        let d = b.display(now: s(20))
        XCTAssertEqual(d?.paused, true)
        XCTAssertNil(d?.endsAt)
        XCTAssertEqual(d?.remaining, 35)
        XCTAssertEqual(d?.fraction ?? -1, 10.0 / 45.0, accuracy: 0.0001)
        b.apply(.timerResume(id: "rest:0.0", endsAt: s(55)), now: s(20))
        XCTAssertEqual(b.alerts(now: s(20)).map(\.fireAt), [s(55)])
        XCTAssertEqual(b.display(now: s(20))?.progressFrom, s(10), "the bar shifts by the paused time")
    }

    func testLockScreenPauseAndResume() {
        var b = TimerBoard()
        b.apply(rest(0, 45), now: s(0))
        b.apply(.pause, now: s(10))
        XCTAssertEqual(b.display(now: s(10))?.remaining, 35)
        XCTAssertTrue(b.alerts(now: s(10)).isEmpty)
        b.apply(.pause, now: s(12))
        XCTAssertEqual(b.display(now: s(12))?.remaining, 35, "pausing twice changes nothing")
        b.apply(.minus15, now: s(15))
        XCTAssertEqual(b.display(now: s(15))?.remaining, 20)
        b.apply(.resume, now: s(30))
        XCTAssertEqual(b.alerts(now: s(30)).map(\.fireAt), [s(50)])
    }

    func testMinus15NeverGoesBelowNow() {
        var b = TimerBoard()
        b.apply(rest(0, 45), now: s(0))
        b.apply(.minus15, now: s(40))
        XCTAssertEqual(b.countdown?.endsAt, s(40))
        XCTAssertTrue(b.alerts(now: s(40)).isEmpty, "already at zero: nothing left to schedule")
    }

    func testMessagesForAnotherTimerAreIgnored() {
        var b = TimerBoard()
        b.apply(rest(0, 45), now: s(0))
        b.apply(.timerEnd(id: "rest:old"), now: s(1))
        b.apply(.timerPause(id: "rest:old", remaining: 3), now: s(1))
        XCTAssertEqual(b.alerts(now: s(1)).map(\.fireAt), [s(45)])
        b.apply(.unknown(type: "timer.lap"), now: s(2))
        XCTAssertEqual(b.alerts(now: s(2)).map(\.fireAt), [s(45)])
    }

    func testStopwatchHold() {
        var b = TimerBoard()
        b.apply(.timerStart(TimerStart(id: "hold:0", kind: .hold, label: "Plank", endsAt: nil, startedAt: s(0), next: "Stop and log")), now: s(0))
        XCTAssertTrue(b.alerts(now: s(0)).isEmpty, "a stopwatch has no zero")
        XCTAssertEqual(b.display(now: s(5))?.countsUpFrom, s(0))
        b.apply(.timerPause(id: "hold:0", remaining: nil), now: s(30))
        XCTAssertEqual(b.display(now: s(40))?.elapsed, 30)
        b.apply(.timerResume(id: "hold:0", endsAt: nil), now: s(40))
        XCTAssertEqual(b.display(now: s(41))?.countsUpFrom, s(10), "the paused time is taken out")
        b.apply(.add15, now: s(42))
        XCTAssertEqual(b.display(now: s(42))?.countsUpFrom, s(10), "±15 means nothing to a stopwatch")
        b.apply(.skip, now: s(50))
        XCTAssertNil(b.countdown, "Skip on a hold is Stop and log")
    }

    func testCountdownThatStartsPaused() {
        // after a long lock the page can start a countdown that's already paused: a start with no end, then a pause
        var b = TimerBoard()
        b.apply(.timerStart(TimerStart(id: "hold:0", kind: .hold, label: "Plank", endsAt: nil, startedAt: s(0), next: "Logged at the time")), now: s(100))
        b.apply(.timerPause(id: "hold:0", remaining: 20), now: s(100))
        XCTAssertEqual(b.display(now: s(100))?.remaining, 20)
        XCTAssertNil(b.display(now: s(100))?.countsUpFrom, "a timed hold, not a stopwatch")
        b.apply(.timerResume(id: "hold:0", endsAt: s(130)), now: s(110))
        XCTAssertEqual(b.alerts(now: s(110)).map(\.fireAt), [s(130)])
    }

    func testIntervalPhasesOneAtATime() {
        // today's page: one phase at a time, no plan ahead. Each phase's bar starts where the last one ended.
        var b = TimerBoard()
        b.apply(.timerStart(TimerStart(id: "int:0:0", kind: .work, label: "Work · round 1 of 3", endsAt: s(30), startedAt: s(0), next: "Recovery, round 1 of 3")), now: s(0))
        XCTAssertEqual(b.alerts(now: s(0)).first?.title, "Work · round 1 of 3 done")
        b.apply(.timerEnd(id: "int:0:0"), now: s(31))
        b.apply(.timerStart(TimerStart(id: "int:0:1", kind: .intervalRest, label: "Recovery · round 1 of 3", endsAt: s(45), startedAt: s(0), next: "Work, round 2 of 3")), now: s(31))
        XCTAssertEqual(b.display(now: s(31))?.progressFrom, s(30))
        XCTAssertEqual(b.alerts(now: s(31)).map(\.fireAt), [s(45)])
    }

    func intervalWithPlan() -> BridgeMessage {
        // 3 rounds of 30 s work / 15 s recovery: phases end at 30, 45, 75, 90, 120
        .timerStart(TimerStart(id: "int:0:0", kind: .work, label: "Work · round 1 of 3", endsAt: s(30), startedAt: s(0), next: "Recovery, round 1 of 3", upcoming: [
            Step(id: "int:0:1", kind: .intervalRest, label: "Recovery · round 1 of 3", endsAt: s(45)),
            Step(id: "int:0:2", kind: .work, label: "Work · round 2 of 3", endsAt: s(75)),
            Step(id: "int:0:3", kind: .intervalRest, label: "Recovery · round 2 of 3", endsAt: s(90)),
            Step(id: "int:0:4", kind: .work, label: "Work · round 3 of 3", endsAt: s(120)),
        ]))
    }

    func testIntervalPlanAheadSchedulesEveryZero() {
        var b = TimerBoard()
        b.apply(intervalWithPlan(), now: s(0))
        let a = b.alerts(now: s(0))
        XCTAssertEqual(a.map(\.fireAt), [s(30), s(45), s(75), s(90), s(120)], "every phase sounds at zero, even with the page asleep")
        XCTAssertEqual(a.last?.body, "That was the last one")
        XCTAssertEqual(a[1].body, "Up next: Work · round 2 of 3")
        XCTAssertEqual(Set(a.map(\.identifier)).count, 5)
        XCTAssertEqual(b.display(now: s(0))?.nextEndsAt, s(45))
        XCTAssertEqual(b.alerts(now: s(50)).map(\.fireAt), [s(75), s(90), s(120)], "past zeros aren't scheduled again")
    }

    func testIntervalPlanMovesWithPauseAndPlus15() {
        var b = TimerBoard()
        b.apply(intervalWithPlan(), now: s(0))
        b.apply(.pause, now: s(10))
        XCTAssertTrue(b.alerts(now: s(10)).isEmpty)
        b.apply(.resume, now: s(20))
        XCTAssertEqual(b.alerts(now: s(20)).map(\.fireAt), [s(40), s(55), s(85), s(100), s(130)], "a pause moves every later zero")
        b.apply(.add15, now: s(21))
        XCTAssertEqual(b.alerts(now: s(21)).map(\.fireAt), [s(55), s(70), s(100), s(115), s(145)], "+15 on this phase moves the rest too")
    }

    func testSkipGoesToTheNextPlannedPhase() {
        var b = TimerBoard()
        b.apply(intervalWithPlan(), now: s(0))
        b.apply(.skip, now: s(10))
        XCTAssertEqual(b.countdown?.id, "int:0:1")
        XCTAssertEqual(b.countdown?.next, "Work · round 2 of 3")
        XCTAssertEqual(b.alerts(now: s(10)).map(\.fireAt), [s(25), s(55), s(70), s(100)], "recovery runs its 15 s from now")
        XCTAssertEqual(b.display(now: s(10))?.progressFrom, s(10))
    }

    func testSkipARestClosesIt() {
        var b = TimerBoard()
        b.apply(rest(0, 45), now: s(0))
        b.apply(.skip, now: s(5))
        XCTAssertNil(b.countdown)
        XCTAssertTrue(b.alerts(now: s(5)).isEmpty)
    }

    func testTooManyAlertsAreCapped() {
        var b = TimerBoard()
        let steps = (1...100).map { Step(id: "int:0:\($0)", kind: .work, label: "x", endsAt: s(Double($0) * 10 + 10)) }
        b.apply(.timerStart(TimerStart(id: "int:0:0", kind: .work, label: "x", endsAt: s(10), startedAt: s(0), next: "x", upcoming: steps)), now: s(0))
        XCTAssertEqual(b.alerts(now: s(0)).count, TimerBoard.alertLimit)
    }

    func testScreenStaysOnWhileTheWorkoutIsGoing() {
        var b = TimerBoard()
        XCTAssertFalse(b.keepAwake(now: s(0)))
        b.apply(.workoutStart(title: "Push A"), now: s(0))
        XCTAssertTrue(b.keepAwake(now: s(60)))
        XCTAssertEqual(b.title, "Push A")
        XCTAssertTrue(b.keepAwake(now: s(TimerBoard.quietLimit - 1)))
        XCTAssertFalse(b.keepAwake(now: s(TimerBoard.quietLimit + 1)), "the page went quiet (closed without saving): let it sleep")
        b.apply(rest(TimerBoard.quietLimit + 5, 600), now: s(TimerBoard.quietLimit + 5))
        XCTAssertTrue(b.keepAwake(now: s(TimerBoard.quietLimit + 500)), "a timer keeps it on")
    }

    func testClosingUnsavedEndsEverything() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Legs A"), now: s(0))
        b.apply(rest(0, 45), now: s(0))
        b.apply(.workoutClose, now: s(5))
        XCTAssertNil(b.countdown)
        XCTAssertTrue(b.alerts(now: s(5)).isEmpty)
        XCTAssertFalse(b.keepAwake(now: s(5)))
        XCTAssertNil(b.lastSummary)
    }

    func testATimerWithNoWorkoutStartsOne() {
        // the app was opened mid-workout: the page's next timer still turns everything on
        var b = TimerBoard()
        b.apply(rest(0, 45), now: s(0))
        XCTAssertEqual(b.title, "Workout")
        XCTAssertNotNil(b.workout)
    }

    // MARK: - Rests from Siri, and messages that aren't about the timer

    func testANativeRestRunsUntilThePageTakesOver() {
        var b = TimerBoard()
        b.startNativeRest(seconds: 90, now: s(0))
        XCTAssertEqual(b.countdown?.id, "virt-rest:1763373600000")
        XCTAssertEqual(b.alerts(now: s(1)).map(\.fireAt), [s(90)])
        XCTAssertEqual(b.alerts(now: s(1)).first?.title, "Rest is over")
        XCTAssertEqual(b.alerts(now: s(1)).first?.body, "Time's up")
        XCTAssertTrue(b.keepAwake(now: s(1)))
        XCTAssertFalse(b.expireNative(now: s(89)), "not yet")
        // the page heard the rest command and started its own
        b.apply(rest(2, 88), now: s(2))
        XCTAssertEqual(b.countdown?.id, "rest:2.0")
        XCTAssertEqual(b.alerts(now: s(3)).map(\.identifier), ["virt.timer.rest:2.0"], "the page's rest replaced Virt's")
        XCTAssertFalse(b.expireNative(now: s(200)), "the page ends its own")
    }

    func testANativeRestNoPageHeardEndsItselfAtZero() {
        var b = TimerBoard()
        b.startNativeRest(seconds: 30, now: s(0))
        XCTAssertTrue(b.expireNative(now: s(30)))
        XCTAssertNil(b.countdown)
        XCTAssertNil(b.display(now: s(30)), "the Live Activity ends")
    }

    func testTodayIsNotASignOfAWorkout() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Legs A"), now: s(0))
        b.apply(.today(TodayInfo(title: "Legs A")), now: s(TimerBoard.quietLimit))
        XCTAssertEqual(b.lastMessageAt, s(0))
        XCTAssertFalse(b.keepAwake(now: s(TimerBoard.quietLimit + 1)))
        b.apply(.setLogged, now: s(TimerBoard.quietLimit + 2))
        XCTAssertTrue(b.keepAwake(now: s(TimerBoard.quietLimit + 3)), "a logged set is")
        XCTAssertNotNil(b.workout)
    }

    func testZeroSoundsFollowTheKind() {
        var b = TimerBoard()
        b.apply(intervalWithPlan(), now: s(0))
        let cues = b.alerts(now: s(0)).map(\.cue)
        XCTAssertEqual(cues.first, .rest, "work ends: rest starts")
        XCTAssertEqual(cues.dropFirst().first, .go, "recovery ends: back to work")
        let lengths = b.alerts(now: s(0)).map(\.length)
        XCTAssertEqual(lengths.dropFirst().first ?? nil, 15, "each phase knows its own length")
    }
}
