import XCTest
@testable import VirtCore

/// What counts as mid-workout (`TimerBoard.midWorkout`): the 45-minute rule behind LiveWorkout, sign out's wait and
/// the sound keeper. (This file held LockPolicy's tests until Nov 28, when Virt's own lock went.)
final class MidWorkoutTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_763_373_600)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }
    let minute: TimeInterval = 60

    // MARK: - TimerBoard.midWorkout

    func testNoWorkoutIsNotMidWorkout() {
        XCTAssertFalse(TimerBoard().midWorkout(now: s(0)))
    }

    func testARunningTimerIsMidWorkout() {
        var b = TimerBoard()
        b.apply(.timerStart(TimerStart(id: "rest:0", kind: .rest, label: "Rest", endsAt: s(10 * minute), startedAt: s(0), next: "")), now: s(0))
        XCTAssertTrue(b.midWorkout(now: s(9 * minute)), "still counting")
        // the page was asleep and never said it ended: the zero itself is the last sign
        XCTAssertTrue(b.midWorkout(now: s(10 * minute + TimerBoard.quietLimit - 1)))
        XCTAssertFalse(b.midWorkout(now: s(10 * minute + TimerBoard.quietLimit + 1)), "a timer that ended long ago isn't a workout going")
    }

    func testBetweenSetsIsMidWorkout() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Legs A"), now: s(0))
        XCTAssertTrue(b.midWorkout(now: s(20 * minute)), "no timer, but the workout is going")
        XCTAssertFalse(b.midWorkout(now: s(TimerBoard.quietLimit + 1)), "a workout left open for ages doesn't count")
    }

    func testAPausedTimerLeftAloneStopsCounting() {
        var b = TimerBoard()
        b.apply(.timerStart(TimerStart(id: "rest:0", kind: .rest, label: "Rest", endsAt: s(90), startedAt: s(0), next: "")), now: s(0))
        b.apply(.timerPause(id: "rest:0", remaining: 80), now: s(10))
        XCTAssertTrue(b.midWorkout(now: s(30 * minute)))
        XCTAssertFalse(b.midWorkout(now: s(10 + TimerBoard.quietLimit + 1)))
    }

    func testALockScreenButtonIsASignOfTheWorkout() {
        var b = TimerBoard()
        b.apply(.timerStart(TimerStart(id: "rest:0", kind: .rest, label: "Rest", endsAt: s(90), startedAt: s(0), next: "")), now: s(0))
        b.apply(.pause, now: s(40 * minute))
        XCTAssertEqual(b.lastButtonAt, s(40 * minute))
        XCTAssertTrue(b.midWorkout(now: s(80 * minute)), "pressed 40 minutes ago, on the lock screen")
        XCTAssertFalse(b.midWorkout(now: s(40 * minute + TimerBoard.quietLimit + 1)))
    }

    func testAFinishedWorkoutIsNotMidWorkout() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Legs A"), now: s(0))
        b.apply(.workoutFinish(WorkoutSummary(mins: 1, exercises: 1, sets: 1, steps: 0)), now: s(60))
        XCTAssertFalse(b.midWorkout(now: s(61)))
        b.apply(.workoutStart(title: "Legs A"), now: s(100))
        b.apply(.workoutClose, now: s(110))
        XCTAssertFalse(b.midWorkout(now: s(111)), "closed without saving")
    }
}
