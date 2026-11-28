import XCTest
@testable import VirtCore

/// Tyler at the gym, Nov 24: Log set from the lock screen logging more than one set, the workout timer's alerts piling
/// up, the green-light sound, and the lock that kept getting in the way.
final class LockScreenFixTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_021_200)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }

    let press = NextSet(exercise: "Chest press machine", set: 1, of: 3, weight: 105, reps: 10,
                        label: "Chest press machine · set 1 of 3 · 105 × 10", rest: 90)

    func boardWithSet(_ n: NextSet? = nil) -> TimerBoard {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        b.apply(.setNext(n ?? press), now: s(1))
        return b
    }

    // MARK: - Log set: one press, one set

    func testOnePressIsOneSet() {
        var b = boardWithSet()
        var gate = LogPress()
        let c = gate.press(board: &b, now: s(10), id: "a")
        XCTAssertEqual(c, .log(at: s(10), id: "a"))
        XCTAssertEqual(b.nextSet?.set, 2, "the board moved on one set")
        XCTAssertEqual(b.countdown?.endsAt, s(100), "its rest started")
    }

    func testPressesInTheSameMomentCountOnce() {
        var b = boardWithSet()
        var gate = LogPress()
        XCTAssertNotNil(gate.press(board: &b, now: s(10), id: "a"))
        XCTAssertNil(gate.press(board: &b, now: s(10.2), id: "b"), "a double tap")
        XCTAssertNil(gate.press(board: &b, now: s(10.7), id: "c"), "still the same burst (0.5 s after the last press)")
        XCTAssertEqual(b.nextSet?.set, 2, "one set for the whole burst")
        XCTAssertNotNil(gate.press(board: &b, now: s(12), id: "d"), "a press after a pause counts")
        XCTAssertEqual(b.nextSet?.set, 3)
    }

    func testNothingIsSentWithNoNextSet() {
        var b = TimerBoard()
        var gate = LogPress()
        XCTAssertNil(gate.press(board: &b, now: s(0), id: "a"), "no workout known (a fresh launch with no copy)")
        b.apply(.workoutStart(title: "Upper A"), now: s(1))
        XCTAssertNil(gate.press(board: &b, now: s(5), id: "b"), "a workout, but no set to log")
        b.apply(.setNext(nil), now: s(6))
        XCTAssertNil(gate.press(board: &b, now: s(10), id: "c"))
    }

    /// Three presses on a three-set exercise, then two more, all with the page asleep: three logs go, never five, and
    /// none past the exercise's last set.
    func testPressesNeverPassTheExercisesLastSet() {
        var b = boardWithSet()
        var gate = LogPress()
        var sent: [PageCommand] = []
        for (i, at) in [10.0, 20, 30, 40, 50].enumerated() {
            if let c = gate.press(board: &b, now: s(at), id: "p\(i)") { sent.append(c) }
        }
        XCTAssertEqual(sent, [.log(at: s(10), id: "p0"), .log(at: s(20), id: "p1"), .log(at: s(30), id: "p2")])
        XCTAssertNil(b.nextSet, "after set 3 of 3, nothing left to log until the page names the next exercise")
    }

    /// The page wakes and answers each log with set.next, sometimes more than once: the board takes the page's word
    /// (it never adds the page's step to its own), so one press stays one set.
    func testSleepAndWakeNeverDoubleAdvance() {
        var b = boardWithSet()
        var gate = LogPress()
        XCTAssertNotNil(gate.press(board: &b, now: s(10), id: "a"))
        XCTAssertEqual(b.nextSet?.set, 2)
        // the page wakes: it logs set 1 and names set 2, twice (a repeat), then starts its own rest
        let two = press.following!
        b.apply(.setLogged, now: s(40))
        b.apply(.setNext(two), now: s(40))
        b.apply(.setNext(two), now: s(41))
        b.apply(.timerStart(TimerStart(id: "rest:10", kind: .rest, label: "Rest", endsAt: s(100), startedAt: s(10),
                                       next: "set 2 of Chest press machine", nextSet: two)), now: s(41))
        XCTAssertEqual(b.nextSet?.set, 2, "still set 2: no double advance")
        XCTAssertEqual(b.display(now: s(41))?.logButton, "Log set 2")
        // the next press logs set 2, and only set 2
        XCTAssertEqual(gate.press(board: &b, now: s(100), id: "b"), .log(at: s(100), id: "b"))
        XCTAssertEqual(b.nextSet?.set, 3)
    }

    func testLogScriptCarriesItsID() {
        XCTAssertEqual(PageCommand.log(at: s(0.5), id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301").script,
                       "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: { command: 'log', at: 1795021200500, id: '3F2504E0-4F89-11D3-9A0C-0305E82C3301' } }));")
        XCTAssertEqual(PageCommand.log(at: s(0), id: "x'); alert(1); ('").script,
                       "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: { command: 'log', at: 1795021200000, id: 'xalert1' } }));",
                       "an id can't break out of its quotes")
        XCTAssertEqual(PageCommand.log(at: s(0)).script,
                       "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: { command: 'log', at: 1795021200000 } }));",
                       "no id: the old shape")
    }

    // MARK: - The timer's alerts in Notification Center

    func testDeliveredTimerAlertsAreTakenAway() {
        let delivered: [(id: String, at: Date)] = [
            ("virt.timer.rest:1", s(0)), ("virt.timer.rest:2", s(100)), ("virt.reminder.2026-11-24", s(50)),
            ("virt.timer.rest:3", s(198.5)),
        ]
        XCTAssertEqual(TimerAlerts.toRemove(delivered: delivered, now: s(200), everything: false),
                       ["virt.timer.rest:1", "virt.timer.rest:2"], "in the background: all but the one still sounding")
        XCTAssertEqual(TimerAlerts.toRemove(delivered: delivered, now: s(200), everything: true),
                       ["virt.timer.rest:1", "virt.timer.rest:2", "virt.timer.rest:3"], "Virt open, or the workout over: all of them")
        XCTAssertFalse(TimerAlerts.toRemove(delivered: delivered, now: s(200), everything: true).contains("virt.reminder.2026-11-24"),
                       "reminders are never touched")
        XCTAssertTrue(TimerAlerts.isTimer("virt.timer.x"))
        XCTAssertFalse(TimerAlerts.isTimer("virt.reminder.x"))
    }

    /// The alerts scheduled: one per zero still ahead, each with a stable identifier, and none once the workout ends.
    func testScheduledAlertsFollowTheBoard() {
        var b = boardWithSet()
        b.apply(.timerStart(TimerStart(id: "rest:1", kind: .rest, label: "Rest", endsAt: s(91), startedAt: s(1), next: "set 2")), now: s(1))
        XCTAssertEqual(b.alerts(now: s(2)).map(\.identifier), ["virt.timer.rest:1"])
        XCTAssertTrue(b.alerts(now: s(2)).allSatisfy { TimerAlerts.isTimer($0.identifier) })
        b.apply(.timerEnd(id: "rest:1"), now: s(91))
        XCTAssertTrue(b.alerts(now: s(91)).isEmpty)
        b.apply(.timerStart(TimerStart(id: "rest:2", kind: .rest, label: "Rest", endsAt: s(200), startedAt: s(110), next: "set 3")), now: s(110))
        XCTAssertEqual(b.alerts(now: s(111)).map(\.identifier), ["virt.timer.rest:2"], "one pending: the next zero")
        b.apply(.workoutFinish(WorkoutSummary(mins: 5, exercises: 1, sets: 3, steps: 0)), now: s(120))
        XCTAssertTrue(b.alerts(now: s(121)).isEmpty, "the workout's over: nothing scheduled")
    }

    // MARK: - The green light

    func testGreenLightLandsOnTheZero() {
        // Nov 27 (build 95): every zero's count-in starts 3 s before it; the green light's tones are its own
        XCTAssertEqual(SoundStyle.chime.lead(.go), 3)
        XCTAssertEqual(SoundStyle.digital.lead(.go), 3)
        XCTAssertEqual(SoundStyle.chime.lead(.rest), 3)
        XCTAssertEqual(SoundStyle.classic.lead(.go), 3)
        XCTAssertNil(SoundStyle.chime.countInTick(.go), "its own three tones are the count-in")
        XCTAssertEqual(SoundStyle.chime.countInTick(.rest), "virt-chime-tick.caf")
        XCTAssertEqual(LeadIn.ticks(zero: s(60), now: s(0), length: 60), [s(57), s(58), s(59)])
    }

    // MARK: - Live workouts and the lock

    func testTodayCarriesLive() {
        let m = BridgeMessage.decode(Data(#"{"type":"today","title":"Upper A","live":true}"#.utf8))
        guard case .today(let t) = m else { return XCTFail("a today") }
        XCTAssertEqual(t.live, true)
        guard case .today(let old) = BridgeMessage.decode(Data(#"{"type":"today","title":"Upper A"}"#.utf8)) else { return XCTFail() }
        XCTAssertNil(old.live, "an older page doesn't say")
        guard case .today(let odd) = BridgeMessage.decode(Data(#"{"type":"today","title":"Upper A","live":"yes"}"#.utf8)) else { return XCTFail() }
        XCTAssertNil(odd.live, "an odd value is skipped, the message kept")
        var a = TodayInfo(title: "Upper A", live: true)
        a.receivedAt = s(0)
        XCTAssertTrue(a.samePlan(as: TodayInfo(title: "Upper A", live: false)), "live alone doesn't redraw the widgets")
        // saved-data rule: a copy with `live` reads in a build that doesn't know it, and the old copy reads here
        let back = TodayInfo.decodeStored(a.encoded()!)
        XCTAssertEqual(back?.live, true)
        XCTAssertNil(TodayInfo.decodeStored(Data(#"{"title":"Upper A"}"#.utf8))?.live)
    }

    func testWhatCountsAsLive() {
        var b = TimerBoard()
        XCTAssertFalse(LiveWorkout.isLive(pageLive: nil, pageSaidAt: nil, board: b, now: s(0)))
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        // an older page: Virt's own 45-minute rule
        XCTAssertTrue(LiveWorkout.isLive(pageLive: nil, pageSaidAt: nil, board: b, now: s(44 * 60)))
        XCTAssertFalse(LiveWorkout.isLive(pageLive: nil, pageSaidAt: nil, board: b, now: s(46 * 60)), "a long break locks with an older page")
        // the page says live: a long break between sets still counts
        XCTAssertTrue(LiveWorkout.isLive(pageLive: true, pageSaidAt: s(0), board: b, now: s(90 * 60)), "a 90-minute break")
        XCTAssertFalse(LiveWorkout.isLive(pageLive: true, pageSaidAt: s(0), board: b, now: s(LiveWorkout.trustLimit + 1)),
                       "a page closed without a word doesn't keep the lock away for ever")
        XCTAssertFalse(LiveWorkout.isLive(pageLive: false, pageSaidAt: s(10), board: b, now: s(20)), "the page says it's over")
        // a running countdown is always live
        b.apply(.timerStart(TimerStart(id: "r", kind: .rest, label: "Rest", endsAt: s(200), startedAt: s(100), next: "")), now: s(100))
        XCTAssertTrue(LiveWorkout.isLive(pageLive: false, pageSaidAt: s(10), board: b, now: s(150)))
    }

    func testLiveIsRememberedAcrossALaunch() {
        let fromPage = LiveWorkout.Memory(live: true, seenAt: s(0), fromPage: true)
        XCTAssertTrue(fromPage.stillLive(now: s(2 * 60 * 60)))
        XCTAssertFalse(fromPage.stillLive(now: s(LiveWorkout.trustLimit)))
        let own = LiveWorkout.Memory(live: true, seenAt: s(0), fromPage: false)
        XCTAssertTrue(own.stillLive(now: s(44 * 60)))
        XCTAssertFalse(own.stillLive(now: s(45 * 60)))
        XCTAssertFalse(LiveWorkout.Memory(live: false, seenAt: s(0), fromPage: true).stillLive(now: s(1)))
        XCTAssertFalse(fromPage.stillLive(now: s(-10)), "a clock that went backward doesn't count")
        XCTAssertEqual(LiveWorkout.Memory.decode(fromPage.encoded()), fromPage)
        XCTAssertNil(LiveWorkout.Memory.decode(Data("odd".utf8)))
        XCTAssertNil(LiveWorkout.Memory.decode(nil))
    }

    func testLockAfterSetting() {
        XCTAssertEqual(LockAfter(stored: nil), .fifteenMinutes, "the standard")
        XCTAssertEqual(LockAfter(stored: "1h"), .oneHour)
        XCTAssertEqual(LockAfter(stored: "from-the-future"), .fifteenMinutes)
        XCTAssertEqual(LockAfter.allCases.map(\.name), ["Right away", "15 minutes", "1 hour", "Never"])
        XCTAssertEqual(LockAfter.rightAway.limit, 0)
        XCTAssertEqual(LockAfter.oneHour.limit, 3600)

        // right away: any time in the background locks, but never mid-workout
        var p = LockPolicy(awayLimit: LockAfter.rightAway.limit)
        p.unlocked()
        p.wentAway(at: 100)
        XCTAssertFalse(p.cameBack(at: 101, midWorkout: true))
        p.wentAway(at: 200)
        XCTAssertTrue(p.cameBack(at: 201, midWorkout: false))

        // an hour
        var h = LockPolicy(awayLimit: LockAfter.oneHour.limit)
        h.unlocked()
        h.wentAway(at: 0)
        XCTAssertFalse(h.cameBack(at: 59 * 60, midWorkout: false))
        h.wentAway(at: 0)
        XCTAssertTrue(h.cameBack(at: 60 * 60, midWorkout: false))

        // never: not after a day, not even with a clock that went backward
        var n = LockPolicy(awayLimit: LockAfter.never.limit)
        n.unlocked()
        n.wentAway(at: 0)
        XCTAssertFalse(n.cameBack(at: 86_400, midWorkout: false))
        n.wentAway(at: 100)
        XCTAssertFalse(n.cameBack(at: 50, midWorkout: false))
    }

    func testALaunchDuringALiveWorkoutOpensStraightIn() {
        XCTAssertTrue(LockPolicy.lockedAtLaunch(lockAfter: .fifteenMinutes, liveWorkout: false))
        XCTAssertTrue(LockPolicy.lockedAtLaunch(lockAfter: .rightAway, liveWorkout: false))
        XCTAssertFalse(LockPolicy.lockedAtLaunch(lockAfter: .rightAway, liveWorkout: true), "never a lock while a workout is live")
        XCTAssertFalse(LockPolicy.lockedAtLaunch(lockAfter: .never, liveWorkout: false))
        let p = LockPolicy(awayLimit: 900, locked: false)
        XCTAssertFalse(p.locked)
        let f = IntroFlow.open(reduceMotion: false)
        XCTAssertEqual(f.stage, .done, "no launch clip")
        XCTAssertFalse(f.playingOut)
        XCTAssertFalse(f.showsUnlockButton)
    }

    // MARK: - The board kept on the phone

    func testTheBoardSurvivesTheAppBeingEnded() {
        var b = boardWithSet()
        var gate = LogPress()
        _ = gate.press(board: &b, now: s(10), id: "a")
        b.apply(.timerStart(TimerStart(id: "rest:10", kind: .rest, label: "Rest", endsAt: s(100), startedAt: s(10), next: "set 2",
                                       upcoming: [Step(id: "w2", kind: .work, label: "Work", endsAt: s(130))], nextSet: press.following)), now: s(12))
        let data = b.snapshot.encoded()!
        let back = TimerBoard.restored(from: TimerBoard.Snapshot.decode(data), now: s(50))
        XCTAssertEqual(back, b, "the same board after a fresh launch")
        XCTAssertEqual(back.alerts(now: s(50)).map(\.identifier), b.alerts(now: s(50)).map(\.identifier))
        // a press after the fresh launch logs the next set, not nothing
        var again = back
        var newGate = LogPress()
        XCTAssertEqual(newGate.press(board: &again, now: s(60), id: "b"), .log(at: s(60), id: "b"))
        XCTAssertEqual(again.nextSet?.set, 3)
    }

    func testAnOldCopyIsDropped() {
        var b = boardWithSet()
        b.apply(.setLogged, now: s(5))
        let old = TimerBoard.restored(from: b.snapshot, now: s(TimerBoard.quietLimit + 60))
        XCTAssertNil(old.workout, "a workout left an hour ago isn't brought back")
        XCTAssertEqual(TimerBoard.restored(from: nil, now: s(0)), TimerBoard())
        XCTAssertNil(TimerBoard.Snapshot.decode(Data("{\"countdown\":7}".utf8)), "a copy that can't be read is no copy")
        // saved-data rule: a copy with fields this build doesn't know still reads
        XCTAssertNotNil(TimerBoard.Snapshot.decode(Data("{\"workoutTitle\":\"Upper A\",\"someday\":1}".utf8)))
    }
}
