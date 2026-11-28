import XCTest
@testable import VirtCore

/// Log set from the lock screen (wayloncore/tyleralocke#573): the page's `set.next` and `nextSet`, the `log` command,
/// and what the Live Activity shows between sets and while resting.
final class LogSetTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_021_200)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }
    func read(_ json: String) -> BridgeMessage? { BridgeMessage.decode(Data(json.utf8)) }

    let press = NextSet(exercise: "Chest press machine", set: 2, of: 4, weight: 105, reps: 10,
                        label: "Chest press machine · set 2 of 4 · 105 × 10", rest: 90)

    func testReadsSetNext() {
        XCTAssertEqual(read(#"{"type":"set.next","next":{"exercise":"Chest press machine","set":2,"of":4,"weight":105,"reps":10,"label":"Chest press machine · set 2 of 4 · 105 × 10","rest":90}}"#),
                       .setNext(press))
        XCTAssertEqual(read(#"{"type":"set.next","next":null}"#), .setNext(nil), "nothing left to log")
        XCTAssertEqual(read(#"{"type":"set.next"}"#), .setNext(nil))
        XCTAssertEqual(read(#"{"type":"set.next","next":{"set":"two","label":5}}"#), .setNext(nil), "an odd one reads as none")
        let words = read(#"{"type":"set.next","next":{"exercise":"Leg press","set":1,"of":3,"weight":null,"reps":8,"label":"Leg press · set 1 of 3 · 4th plate × 8","extra":true}}"#)
        XCTAssertEqual(words, .setNext(NextSet(exercise: "Leg press", set: 1, of: 3, weight: nil, reps: 8, label: "Leg press · set 1 of 3 · 4th plate × 8")))
    }

    func testTimerStartCarriesTheNextSet() {
        let m = read(#"{"type":"timer.start","id":"rest:1","kind":"rest","label":"Rest","endsAt":91000,"startedAt":1000,"next":{"label":"set 2 of Chest press machine"},"nextSet":{"exercise":"Chest press machine","set":2,"of":4,"weight":105,"reps":10,"label":"Chest press machine · set 2 of 4 · 105 × 10","rest":90}}"#)
        guard case .timerStart(let t) = m else { return XCTFail("a timer.start") }
        XCTAssertEqual(t.nextSet, press)
        XCTAssertEqual(t.next, "set 2 of Chest press machine")
        let old = read(#"{"type":"timer.start","id":"rest:1","kind":"rest","label":"Rest","endsAt":91000,"startedAt":1000,"next":{"label":"x"},"nextSet":"odd"}"#)
        guard case .timerStart(let o) = old else { return XCTFail("an odd nextSet never loses the message") }
        XCTAssertNil(o.nextSet)
    }

    func testNextSetWords() {
        XCTAssertEqual(press.detail, "set 2 of 4 · 105 × 10")
        XCTAssertEqual(press.after, "set 3 of Chest press machine")
        XCTAssertEqual(press.following?.label, "Chest press machine · set 3 of 4 · 105 × 10")
        XCTAssertEqual(press.following?.set, 3)
        XCTAssertNil(press.following?.following?.following, "none after the last set")
    }

    func testLogScript() {
        XCTAssertEqual(PageCommand.log(at: Date(timeIntervalSince1970: 1_795_021_200.5)).script,
                       "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: { command: 'log', at: 1795021200500 } }));")
        XCTAssertEqual(TimerCommand.log.script, "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: 'log' }));")
    }

    /// Between sets: the next set and Log set. Log set starts its rest at once (the page may be asleep), the next set
    /// shows one on, and the page's own rest and set.next then take over.
    func testBetweenSetsThenLogSetThenRest() {
        var b = TimerBoard()
        XCTAssertNil(b.display(now: s(0)))
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        XCTAssertNil(b.display(now: s(0)), "no next set yet: no activity")
        b.apply(.setNext(press), now: s(1))
        let between = b.display(now: s(1))
        XCTAssertEqual(between?.betweenSets, true)
        XCTAssertEqual(between?.logButton, "Log set 2")
        XCTAssertEqual(between?.setExercise, "Chest press machine")
        XCTAssertEqual(between?.setDetail, "set 2 of 4 · 105 × 10")
        XCTAssertNil(between?.endsAt)
        XCTAssertTrue(b.alerts(now: s(1)).isEmpty, "nothing to sound between sets")

        // Log set on the lock screen: the 90 s rest starts right away, with the next set (one on) under it
        b.apply(.log, now: s(10))
        XCTAssertEqual(b.countdown?.endsAt, s(100))
        XCTAssertEqual(b.alerts(now: s(10)).map(\.fireAt), [s(100)])
        let resting = b.display(now: s(10))
        XCTAssertNil(resting?.betweenSets)
        XCTAssertEqual(resting?.nextSet, "Chest press machine · set 3 of 4 · 105 × 10")
        XCTAssertEqual(resting?.logButton, "Log set 3", "Log set still works at the rest's zero, page asleep")
        XCTAssertEqual(b.countdown?.next, "set 3 of Chest press machine")

        // the page wakes: its rest (from the same moment) and its next set replace Virt's
        b.apply(.setLogged(exercise: nil), now: s(30))
        b.apply(.timerStart(TimerStart(id: "rest:10", kind: .rest, label: "Rest", endsAt: s(100), startedAt: s(10),
                                       next: "set 3 of Chest press machine", nextSet: press.following)), now: s(30))
        XCTAssertEqual(b.countdown?.id, "rest:10")
        XCTAssertEqual(b.alerts(now: s(30)).map(\.fireAt), [s(100)], "the same zero")
        XCTAssertEqual(b.display(now: s(30))?.progressFrom, s(10))

        // zero: back to the next set and Log set
        b.apply(.timerEnd(id: "rest:10"), now: s(100))
        XCTAssertEqual(b.display(now: s(100))?.logButton, "Log set 3")
        XCTAssertEqual(b.display(now: s(100))?.betweenSets, true)

        // the page says there's nothing left: the activity ends; a finish clears it too
        b.apply(.setNext(nil), now: s(110))
        XCTAssertNil(b.display(now: s(110)))
        b.apply(.setNext(press), now: s(120))
        b.apply(.workoutFinish(WorkoutSummary(mins: 30, exercises: 4, sets: 16, steps: 0)), now: s(130))
        XCTAssertNil(b.nextSet)
        XCTAssertNil(b.display(now: s(130)))
    }

    func testLogWithNothingToLogDoesNothing() {
        var b = TimerBoard()
        b.apply(.log, now: s(0))
        XCTAssertNil(b.countdown)
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        b.apply(.log, now: s(1))
        XCTAssertNil(b.countdown, "no next set: nothing happens")
        XCTAssertNil(b.lastButtonAt)
    }

    /// The last set with no rest: "Logged" shows until the page says what's next, so the activity doesn't end.
    func testLastSetWithNoRest() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        b.apply(.setNext(NextSet(exercise: "Push-up", set: 3, of: 3, reps: 15, label: "Push-up · set 3 of 3 · 15 reps")), now: s(0))
        b.apply(.log, now: s(5))
        XCTAssertNil(b.countdown)
        XCTAssertNil(b.nextSet)
        XCTAssertEqual(b.display(now: s(5))?.setDetail, "Logged · set 3 of 3 · 15 reps")
        XCTAssertNil(b.display(now: s(5))?.logButton)
        b.apply(.setNext(press), now: s(8))
        XCTAssertEqual(b.display(now: s(8))?.logButton, "Log set 2", "the page opened the next exercise")
    }

    func testBetweenSetsGoesQuietAfterTheLimit() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        b.apply(.setNext(press), now: s(0))
        XCTAssertNotNil(b.display(now: s(TimerBoard.quietLimit - 1)))
        XCTAssertNil(b.display(now: s(TimerBoard.quietLimit + 1)))
    }

    /// Saved-data rule: an activity saved by the version before (no new fields) still reads.
    func testOldDisplayStillReads() throws {
        let old = #"{"id":"rest:1","kind":"rest","label":"Rest","next":"set 2 of Plank","paused":false}"#
        let d = try JSONDecoder().decode(TimerDisplay.self, from: Data(old.utf8))
        XCTAssertNil(d.nextSet)
        XCTAssertNil(d.logButton)
        XCTAssertNil(d.betweenSets)
        var n = d
        n.nextSet = press.label
        let back = try JSONDecoder().decode(TimerDisplay.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n)
    }
}
