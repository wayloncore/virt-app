import XCTest
@testable import VirtCore

/// When Virt locks behind Face ID: a fresh launch, 15 minutes away, never mid-workout, and what counts as mid-workout.
final class LockPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_763_373_600)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }
    let minute: TimeInterval = 60

    // MARK: - LockPolicy

    func testAFreshLaunchStartsLocked() {
        var p = LockPolicy()
        XCTAssertTrue(p.locked)
        XCTAssertEqual(p.awayLimit, 15 * 60)
        XCTAssertTrue(p.cameBack(at: 0, midWorkout: true), "a fresh launch stays locked, even mid-workout")
        p.unlocked()
        XCTAssertFalse(p.locked)
    }

    func testAShortTripAwayStaysUnlocked() {
        var p = LockPolicy()
        p.unlocked()
        p.wentAway(at: 1000)
        XCTAssertFalse(p.cameBack(at: 1000 + 5 * minute, midWorkout: false))
        XCTAssertNil(p.awaySince)
        p.wentAway(at: 2000)
        XCTAssertFalse(p.cameBack(at: 2000 + 15 * minute - 1, midWorkout: false), "14:59 away: still open")
    }

    func testFifteenMinutesAwayLocks() {
        var p = LockPolicy()
        p.unlocked()
        p.wentAway(at: 1000)
        XCTAssertTrue(p.cameBack(at: 1000 + 15 * minute, midWorkout: false))
        XCTAssertTrue(p.locked)
    }

    func testNeverLocksMidWorkout() {
        var p = LockPolicy()
        p.unlocked()
        p.wentAway(at: 1000)
        XCTAssertFalse(p.cameBack(at: 1000 + 90 * minute, midWorkout: true), "coming back mid-workout never asks")
        p.wentAway(at: 9000)
        XCTAssertTrue(p.cameBack(at: 9000 + 20 * minute, midWorkout: false), "the workout's over: it locks")
    }

    func testLockedStaysLockedUntilUnlocked() {
        var p = LockPolicy()
        p.unlocked()
        p.wentAway(at: 0)
        p.cameBack(at: 20 * minute, midWorkout: false)
        p.wentAway(at: 20 * minute)
        XCTAssertTrue(p.cameBack(at: 20 * minute + 1, midWorkout: true), "nothing but Face ID or the passcode unlocks it")
        XCTAssertTrue(p.locked)
    }

    func testGoingAwayTwiceKeepsTheFirstTime() {
        var p = LockPolicy()
        p.unlocked()
        p.wentAway(at: 100)
        p.wentAway(at: 100 + 14 * minute)
        XCTAssertEqual(p.awaySince, 100)
        XCTAssertTrue(p.cameBack(at: 100 + 16 * minute, midWorkout: false))
    }

    func testAClockThatWentBackwardLocks() {
        XCTAssertTrue(LockPolicy.shouldLock(away: -5, midWorkout: false))
        var p = LockPolicy()
        p.unlocked()
        p.wentAway(at: 5000)
        XCTAssertTrue(p.cameBack(at: 10, midWorkout: false))
    }

    func testComingBackWithoutGoingAwayChangesNothing() {
        var p = LockPolicy()
        p.unlocked()
        XCTAssertFalse(p.cameBack(at: 99_999, midWorkout: false))
    }

    func testAShorterLimit() {
        var p = LockPolicy(awayLimit: 2)
        p.unlocked()
        p.wentAway(at: 0)
        XCTAssertFalse(p.cameBack(at: 1.5, midWorkout: false))
        p.wentAway(at: 10)
        XCTAssertTrue(p.cameBack(at: 12, midWorkout: false))
    }

    func testTheRuleItself() {
        XCTAssertFalse(LockPolicy.shouldLock(away: 0, midWorkout: false))
        XCTAssertFalse(LockPolicy.shouldLock(away: 899, midWorkout: false))
        XCTAssertTrue(LockPolicy.shouldLock(away: 900, midWorkout: false))
        XCTAssertFalse(LockPolicy.shouldLock(away: 86_400, midWorkout: true))
        XCTAssertTrue(LockPolicy.shouldLock(away: 60, limit: 30, midWorkout: false))
    }

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
        XCTAssertFalse(b.midWorkout(now: s(10 * minute + TimerBoard.quietLimit + 1)), "a timer that ended long ago doesn't hold the lock off")
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
