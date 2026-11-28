import XCTest
@testable import VirtCore

/// A superset or circuit on the lock screen (Tyler, Nov 27): the next set after a Log set is the one the page says
/// (`then`: the next exercise of the round, never the same exercise again), and a rest that runs out with nothing to
/// log by a press says what's next instead of sitting at 0:00. A made-up circuit: a push-up (2 rounds), a row
/// (3 rounds) and a plank (a timed hold, 3 rounds).
final class CircuitOrderTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_021_200)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }
    func read(_ json: String) -> BridgeMessage? { BridgeMessage.decode(Data(json.utf8)) }

    /// Round 1's push-up as the page sends it: the row follows it (a 15 s switch), then nothing a press can log (the
    /// plank is timed).
    let pushUp = #"{"exercise":"TRX push-up","set":1,"of":2,"weight":null,"reps":10,"label":"Round 1 of 3 · TRX push-up · 10 reps","rest":15,"after":"Seated row machine","then":[{"exercise":"Seated row machine","set":1,"of":3,"weight":115,"reps":10,"label":"Round 1 of 3 · Seated row machine · 115 × 10","rest":15,"after":"Plank"}]}"#

    func testReadsThenAndAfter() {
        guard case .setNext(let n?) = read(#"{"type":"set.next","next":\#(pushUp)}"#) else { return XCTFail("a set.next") }
        XCTAssertEqual(n.exercise, "TRX push-up")
        XCTAssertEqual(n.rest, 15)
        XCTAssertEqual(n.after, "Seated row machine", "the page's own words for what the switch leads to")
        XCTAssertEqual(n.thenSets?.map(\.exercise), ["Seated row machine"])
        XCTAssertEqual(n.following?.label, "Round 1 of 3 · Seated row machine · 115 × 10")
        XCTAssertEqual(n.following?.after, "Plank")
        XCTAssertEqual(n.following?.thenSets, [], "after the row the page listed nothing: Virt doesn't guess")
        XCTAssertNil(n.following?.following, "the plank is timed: no Log set for it")
    }

    func testThenNullOrOddMeansNothingToLogNext() {
        guard case .setNext(let a?) = read(#"{"type":"set.next","next":{"exercise":"Row","set":1,"of":3,"label":"Round 1 of 3 · Row","then":null}}"#) else { return XCTFail() }
        XCTAssertEqual(a.thenSets, [])
        XCTAssertNil(a.following, "the page said none: never the same exercise again")
        XCTAssertEqual(a.after, "")
        guard case .setNext(let b?) = read(#"{"type":"set.next","next":{"exercise":"Row","set":1,"of":3,"label":"Round 1 of 3 · Row","then":"odd"}}"#) else { return XCTFail("an odd then never loses the message") }
        XCTAssertEqual(b.thenSets, [])
        guard case .setNext(let c?) = read(#"{"type":"set.next","next":{"exercise":"Row","set":1,"of":3,"label":"Round 1 of 3 · Row","then":[{"label":5},{"exercise":"Curl","set":1,"of":3,"label":"Round 1 of 3 · Curl"}]}}"#) else { return XCTFail() }
        XCTAssertEqual(c.thenSets?.map(\.exercise), ["Curl"], "an odd entry is skipped")
    }

    /// An older page sends no `then`: Virt guesses as before (the same exercise, one set on).
    func testWithoutThenTheOldGuessStays() {
        guard case .setNext(let n?) = read(#"{"type":"set.next","next":{"exercise":"Chest press machine","set":2,"of":4,"weight":105,"reps":10,"label":"Chest press machine · set 2 of 4 · 105 × 10","rest":90}}"#) else { return XCTFail() }
        XCTAssertNil(n.thenSets)
        XCTAssertEqual(n.following?.label, "Chest press machine · set 3 of 4 · 105 × 10")
        XCTAssertEqual(n.after, "set 3 of Chest press machine")
    }

    /// A plain exercise from a newer page: `then` lists its remaining sets, and the words stay "set 3 of …".
    func testAPlainExercisesThen() {
        let third = NextSet(exercise: "Chest press machine", set: 3, of: 4, weight: 105, reps: 10, label: "Chest press machine · set 3 of 4 · 105 × 10", rest: 90)
        let fourth = NextSet(exercise: "Chest press machine", set: 4, of: 4, weight: 105, reps: 10, label: "Chest press machine · set 4 of 4 · 105 × 10", rest: 90)
        let n = NextSet(exercise: "Chest press machine", set: 2, of: 4, weight: 105, reps: 10, label: "Chest press machine · set 2 of 4 · 105 × 10", rest: 90, then: [third, fourth])
        XCTAssertEqual(n.after, "set 3 of Chest press machine")
        XCTAssertEqual(n.following?.set, 3)
        XCTAssertEqual(n.following?.following?.set, 4)
        XCTAssertNil(n.following?.following?.following, "none after the last set")
    }

    /// Two presses with the page asleep: the push-up, then the row (not the push-up again), then no Log set, and at
    /// the switch's zero the lock screen says the plank is next.
    func testTwoPressesWithThePageAsleep() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Made-up circuit"), now: s(0))
        b.apply(read(#"{"type":"set.next","next":\#(pushUp)}"#)!, now: s(0))
        XCTAssertEqual(b.display(now: s(1))?.setExercise, "TRX push-up")

        b.apply(.log, now: s(10))
        XCTAssertEqual(b.nextSet?.exercise, "Seated row machine", "the next exercise of the round")
        XCTAssertEqual(b.countdown?.endsAt, s(25), "the 15 s switch starts at once")
        XCTAssertEqual(b.countdown?.next, "Seated row machine")
        let switching = b.display(now: s(11))
        XCTAssertEqual(switching?.logButton, "Log set 1")
        XCTAssertEqual(switching?.setExercise, "Seated row machine")
        // its zero: between sets, the row and Log set
        let between = b.display(now: s(26))
        XCTAssertEqual(between?.betweenSets, true)
        XCTAssertEqual(between?.setExercise, "Seated row machine")
        XCTAssertEqual(between?.logButton, "Log set 1")

        b.apply(.log, now: s(40))
        XCTAssertNil(b.nextSet, "the plank is timed: nothing for a press to log")
        XCTAssertEqual(b.countdown?.next, "Plank")
        XCTAssertNil(b.display(now: s(41))?.logButton)
        XCTAssertEqual(b.display(now: s(41))?.endsAt, s(55))
        // the switch's zero with nothing to log: what's next, in words, and no clock at 0:00
        let over = b.display(now: s(56))
        XCTAssertEqual(over?.betweenSets, true)
        XCTAssertEqual(over?.setExercise, "Plank")
        XCTAssertEqual(over?.setDetail, "Rest over · up next")
        XCTAssertNil(over?.endsAt)
        XCTAssertNil(over?.logButton)
        // a third press does nothing
        let before = b
        b.apply(.log, now: s(60))
        XCTAssertEqual(b.countdown, before.countdown)
        XCTAssertNil(b.nextSet)
    }

    /// The page awake: its own switch and next set replace Virt's, and say the same thing.
    func testThePagesAnswerMatches() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Made-up circuit"), now: s(0))
        b.apply(read(#"{"type":"set.next","next":\#(pushUp)}"#)!, now: s(0))
        b.apply(.log, now: s(10))
        let guess = b.nextSet
        b.apply(read(#"{"type":"timer.start","id":"rest:10","kind":"rest","label":"Rest","endsAt":\#(Int((t0.timeIntervalSince1970 + 25) * 1000)),"startedAt":\#(Int((t0.timeIntervalSince1970 + 10) * 1000)),"next":{"label":"Seated row machine"},"nextSet":{"exercise":"Seated row machine","set":1,"of":3,"weight":115,"reps":10,"label":"Round 1 of 3 · Seated row machine · 115 × 10","rest":15,"after":"Plank","then":[]}}"#)!, now: s(11))
        XCTAssertEqual(b.countdown?.id, "rest:10")
        XCTAssertEqual(b.countdown?.endsAt, s(25), "the same zero")
        XCTAssertEqual(b.nextSet, guess, "what Virt showed while the page slept is what the page says")
    }

    /// The Live Activity's own saved content, drawn at the zero with nobody awake (the stale date): a rest with a set
    /// to log moves to Log set; a rest with none says what's next; never the clock at 0:00.
    func testTheActivityAtARestsZero() {
        var withSet = TimerDisplay(id: "rest:1", kind: .rest, label: "Rest", next: "round 2 of 3", endsAt: s(60), progressFrom: s(0))
        withSet.nextSet = "Round 2 of 3 · TRX push-up · 10 reps"
        withSet.logButton = "Log set 2"
        withSet.setExercise = "TRX push-up"
        XCTAssertEqual(withSet.current(at: s(59)).endsAt, s(60), "still counting before the zero")
        XCTAssertEqual(withSet.current(at: s(61)).logButton, "Log set 2")
        XCTAssertEqual(withSet.current(at: s(61)).betweenSets, true)

        let none = TimerDisplay(id: "rest:2", kind: .rest, label: "Rest", next: "Plank", endsAt: s(15), progressFrom: s(0))
        XCTAssertEqual(none.current(at: s(14)).endsAt, s(15))
        let over = none.current(at: s(16))
        XCTAssertEqual(over.betweenSets, true)
        XCTAssertEqual(over.setExercise, "Plank")
        XCTAssertNil(over.endsAt, "no clock left at 0:00")
        XCTAssertEqual(over.current(at: s(600)), over, "and it stays that way")

        let unnamed = TimerDisplay(id: "rest:3", kind: .rest, label: "Rest", next: "", endsAt: s(15), progressFrom: s(0))
        XCTAssertEqual(unnamed.current(at: s(16)).setExercise, "Rest over")
        XCTAssertEqual(unnamed.current(at: s(16)).setDetail, "")

        // a paused rest and a hold are left alone
        var paused = none
        paused.paused = true
        XCTAssertEqual(paused.current(at: s(16)), paused)
        let hold = TimerDisplay(id: "hold:1", kind: .hold, label: "Plank", next: "Logged at the time", endsAt: s(30), progressFrom: s(0))
        XCTAssertEqual(hold.current(at: s(31)), hold)
    }

    /// The page awake at a rest's zero with the plank next: it sends `timer.end` and nothing else. The Live Activity
    /// says what's next until the plank's timer starts; a skipped rest, a rest Virt started itself and a finished
    /// workout just end as before.
    func testThePagesRestEndsWithNothingToLog() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Made-up circuit"), now: s(0))
        b.apply(.setNext(nil), now: s(0))
        let rest = TimerStart(id: "rest:0", kind: .rest, label: "Rest", endsAt: s(15), startedAt: s(0), next: "Plank")
        b.apply(.timerStart(rest), now: s(0))
        b.apply(.timerEnd(id: "rest:0"), now: s(15))
        let over = b.display(now: s(16))
        XCTAssertEqual(over?.betweenSets, true)
        XCTAssertEqual(over?.setExercise, "Plank")
        XCTAssertEqual(over?.setDetail, "Rest over · up next")
        XCTAssertNil(over?.logButton)
        XCTAssertTrue(b.alerts(now: s(16)).isEmpty)
        // the plank's own timer replaces it
        b.apply(.timerStart(TimerStart(id: "hold:20", kind: .hold, label: "Plank", endsAt: nil, startedAt: s(20), next: "Stop and log")), now: s(20))
        XCTAssertEqual(b.display(now: s(21))?.label, "Plank")
        XCTAssertNil(b.restOver)
        // a set to log comes first
        b.apply(.timerEnd(id: "hold:20"), now: s(40))
        b.apply(.timerStart(TimerStart(id: "rest:40", kind: .rest, label: "Rest", endsAt: s(100), startedAt: s(40), next: "round 2 of 3")), now: s(40))
        b.apply(.setNext(NextSet(exercise: "TRX push-up", set: 2, of: 2, reps: 10, label: "Round 2 of 3 · TRX push-up · 10 reps")), now: s(40))
        b.apply(.timerEnd(id: "rest:40"), now: s(100))
        XCTAssertEqual(b.display(now: s(101))?.logButton, "Log set 2")
        // Skip on a rest: no "rest over"
        var c = TimerBoard()
        c.apply(.workoutStart(title: "Made-up circuit"), now: s(0))
        c.apply(.timerStart(rest), now: s(0))
        c.apply(.timerCancel(id: "rest:0"), now: s(5))
        XCTAssertNil(c.display(now: s(6)))
        // the workout finished: nothing left
        c.apply(.timerStart(rest), now: s(10))
        c.apply(.timerEnd(id: "rest:0"), now: s(25))
        c.apply(.workoutFinish(WorkoutSummary(mins: 30, exercises: 4, sets: 16, steps: 0)), now: s(30))
        XCTAssertNil(c.display(now: s(31)))
        // long after, it's gone with the workout's other signs
        var d = TimerBoard()
        d.apply(.workoutStart(title: "Made-up circuit"), now: s(0))
        d.apply(.timerStart(rest), now: s(0))
        d.apply(.timerEnd(id: "rest:0"), now: s(15))
        XCTAssertNil(d.display(now: s(15 + TimerBoard.quietLimit + 1)))
    }

    /// Kept on the phone and read back by the version before: `then` and `after` are added, optional fields.
    func testSavedCopyStaysReadable() throws {
        guard case .setNext(let n?) = read(#"{"type":"set.next","next":\#(pushUp)}"#) else { return XCTFail() }
        let back = try JSONDecoder().decode(NextSet.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n)
        let old = #"{"exercise":"Chest press machine","set":2,"of":4,"weight":105,"reps":10,"label":"Chest press machine · set 2 of 4 · 105 × 10","rest":90}"#
        let fromOld = try JSONDecoder().decode(NextSet.self, from: Data(old.utf8))
        XCTAssertNil(fromOld.thenSets)
        XCTAssertNil(fromOld.afterSaid)
        XCTAssertEqual(fromOld.following?.set, 3)
    }
}
