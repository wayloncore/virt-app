import XCTest
@testable import VirtCore

/// A rest's words on the lock screen and in the Dynamic Island (Tyler, Nov 27: "instead of the word rest between
/// workouts I want next exercise starts in: ... but in between reps/sets it's still rest"): "Next exercise" before a
/// different exercise, "Rest" between sets of the same one and between a circuit's rounds, as the website says them.
final class RestWordsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_280_400)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }

    func press(_ set: Int, of: Int = 4, then: [NextSet]? = nil, after: String? = nil) -> NextSet {
        NextSet(exercise: "Chest press machine", set: set, of: of, weight: 105, reps: 10,
                label: "Chest press machine · set \(set) of \(of) · 105 × 10", rest: 90, then: then, after: after)
    }
    let legPress = NextSet(exercise: "Leg press", set: 1, of: 3, weight: 180, reps: 12, label: "Leg press · set 1 of 3 · 180 × 12", rest: 90)
    let row = NextSet(exercise: "Seated row machine", set: 1, of: 3, weight: 90, reps: 12,
                      label: "Round 1 of 3 · Seated row machine · 90 × 12", rest: 15)
    let pushUpRound2 = NextSet(exercise: "TRX push-up", set: 2, of: 3, reps: 10, label: "Round 2 of 3 · TRX push-up · 10 reps", rest: 15)

    func board() -> TimerBoard {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        return b
    }

    func pageRest(_ at: TimeInterval, next: String, nextSet: NextSet? = nil, label: String = "Rest") -> BridgeMessage {
        .timerStart(TimerStart(id: "rest:\(at)", kind: .rest, label: label, endsAt: s(at + 90), startedAt: s(at), next: next, nextSet: nextSet))
    }

    func testTheWords() {
        XCTAssertEqual(RestWords.rest, "Rest")
        XCTAssertEqual(RestWords.nextExercise, "Next exercise")
        XCTAssertEqual(RestWords.short("Next exercise"), "Next", "the Dynamic Island's narrow corner")
        XCTAssertEqual(RestWords.short("Rest"), "Rest")
        XCTAssertEqual(RestWords.short("Work · round 2 of 6"), "Work · round 2 of 6")
    }

    // MARK: - The page's own rests

    func testBetweenSetsOfTheSameExerciseItsRest() {
        var b = board()
        b.apply(.setNext(press(2)), now: s(0))
        b.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        b.apply(pageRest(10, next: "set 3 of Chest press machine", nextSet: press(3)), now: s(10))
        XCTAssertEqual(b.display(now: s(11))?.label, "Rest")
        // a page that leaves nextSet off: its own words say another set of the same exercise
        var c = board()
        c.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        c.apply(pageRest(10, next: "set 3 of Chest press machine"), now: s(10))
        XCTAssertEqual(c.display(now: s(11))?.label, "Rest")
    }

    func testBeforeTheNextExerciseItsNextExercise() {
        var b = board()
        b.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        b.apply(pageRest(10, next: "Leg press", nextSet: legPress), now: s(10))
        let d = b.display(now: s(11))
        XCTAssertEqual(d?.label, "Next exercise")
        XCTAssertEqual(d?.shortLabel, "Next")
        XCTAssertEqual(d?.kind, .rest, "still a rest: the same icon, sound and buttons")
        XCTAssertEqual(d?.setExercise, "Leg press", "and the next exercise's name over it")
        // no nextSet: the page's own words name the next exercise
        var c = board()
        c.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        c.apply(pageRest(10, next: "Leg press"), now: s(10))
        XCTAssertEqual(c.display(now: s(11))?.label, "Next exercise")
    }

    func testTheOrderTheMessagesComeInDoesNotMatter() {
        var b = board()
        b.apply(pageRest(10, next: "Leg press", nextSet: legPress), now: s(10))
        b.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        b.apply(.setNext(legPress), now: s(10))
        XCTAssertEqual(b.display(now: s(11))?.label, "Next exercise")
    }

    func testAPairsSwitchAndACircuitsRounds() {
        // the 15 s switch to the partner: a different exercise
        var b = board()
        b.apply(.setLogged(exercise: "TRX push-up"), now: s(10))
        b.apply(pageRest(10, next: "Seated row machine", nextSet: row), now: s(10))
        XCTAssertEqual(b.display(now: s(11))?.label, "Next exercise")
        // the rest between rounds stays "Rest", as on the website ("Rest · then round 2 of 3"), even though the round
        // starts with another exercise
        b.apply(.setLogged(exercise: "Seated row machine"), now: s(40))
        b.apply(pageRest(40, next: "round 2 of 3", nextSet: pushUpRound2), now: s(40))
        XCTAssertEqual(b.display(now: s(41))?.label, "Rest")
        XCTAssertEqual(RestWords.label(logged: "Plank", nextSet: nil, next: "Round 3 of 3"), "Rest")
    }

    func testATimedExercisesTurnIsTheNextExercise() {
        var b = board()
        b.apply(.setLogged(exercise: "Seated row machine"), now: s(10))
        b.apply(.setNext(nil), now: s(10))
        b.apply(pageRest(10, next: "Plank"), now: s(10))
        XCTAssertEqual(b.display(now: s(11))?.label, "Next exercise")
    }

    func testRestWhenVirtCantTell() {
        // nothing logged yet: a rest from Siri or a quick action
        var b = board()
        b.startNativeRest(seconds: 90, now: s(5))
        XCTAssertEqual(b.display(now: s(6))?.label, "Rest")
        // the workout's last rest: the page has nothing to name
        var c = board()
        c.apply(.setLogged(exercise: "Leg press"), now: s(10))
        c.apply(.setNext(nil), now: s(10))
        c.apply(pageRest(10, next: "the next one"), now: s(10))
        XCTAssertEqual(c.display(now: s(11))?.label, "Rest")
        XCTAssertEqual(RestWords.label(logged: nil, nextSet: legPress, next: "Leg press"), "Rest")
        XCTAssertEqual(RestWords.label(logged: "  ", nextSet: legPress, next: "Leg press"), "Rest")
    }

    func testOnlyAPlainRestIsRenamed() {
        var b = board()
        b.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        b.apply(pageRest(10, next: "Leg press", nextSet: legPress, label: "Cool-down"), now: s(10))
        XCTAssertEqual(b.display(now: s(11))?.label, "Cool-down", "a rest the page named its own way keeps its name")
        b.apply(.timerStart(TimerStart(id: "hold:20", kind: .hold, label: "Plank", endsAt: s(65), startedAt: s(20), next: "Logged at the time")), now: s(20))
        XCTAssertEqual(b.display(now: s(21))?.label, "Plank", "only rests")
    }

    func testTheNamesAreComparedLoosely() {
        XCTAssertEqual(RestWords.label(logged: "Chest press machine", nextSet: nil, next: "Set 3 of chest press machine "), "Rest")
        XCTAssertEqual(RestWords.label(logged: "Leg press", nextSet: nil, next: " leg press"), "Rest")
    }

    // MARK: - A rest Virt starts itself after a locked Log set

    func testLogSetBetweenSetsIsRest() {
        var b = board()
        b.apply(.setNext(press(2, then: [press(3), press(4)])), now: s(0))
        b.apply(.log, now: s(10))
        XCTAssertNotNil(b.countdown, "its rest started at once")
        XCTAssertEqual(b.display(now: s(11))?.label, "Rest")
        XCTAssertEqual(b.loggedExercise, "Chest press machine")
    }

    func testLogSetOnTheLastSetIsNextExercise() {
        // a newer page: `then` is empty after the exercise's last set, and nothing names what's next
        var b = board()
        b.apply(.setNext(press(4, then: [])), now: s(0))
        b.apply(.log, now: s(10))
        XCTAssertEqual(b.display(now: s(11))?.label, "Next exercise")
        XCTAssertTrue(b.loggedLastSet)
        // an older page (no `then`): the same, from the set's own number
        var c = board()
        c.apply(.setNext(press(4)), now: s(0))
        c.apply(.log, now: s(10))
        XCTAssertEqual(c.display(now: s(11))?.label, "Next exercise")
        var d = board()
        d.apply(.setNext(press(2)), now: s(0))
        d.apply(.log, now: s(10))
        XCTAssertEqual(d.display(now: s(11))?.label, "Rest", "an older page, mid-exercise: Virt's guess is the same exercise")
        // the page wakes and says what's next: its words win
        c.apply(.setLogged(exercise: "Chest press machine"), now: s(20))
        XCTAssertFalse(c.loggedLastSet)
        c.apply(pageRest(10, next: "Leg press", nextSet: legPress), now: s(20))
        XCTAssertEqual(c.display(now: s(21))?.label, "Next exercise")
    }

    func testLogSetInACircuit() {
        let pushUp = NextSet(exercise: "TRX push-up", set: 1, of: 3, reps: 10, label: "Round 1 of 3 · TRX push-up · 10 reps", rest: 15,
                             then: [row], after: "Seated row machine")
        var b = board()
        b.apply(.setNext(pushUp), now: s(0))
        b.apply(.log, now: s(10))
        XCTAssertEqual(b.display(now: s(11))?.label, "Next exercise", "the switch to the row")
        // the round's last exercise: its rest leads to round 2, "Rest"
        let rowLast = NextSet(exercise: "Seated row machine", set: 1, of: 3, weight: 90, reps: 12,
                              label: "Round 1 of 3 · Seated row machine · 90 × 12", rest: 60, then: [pushUpRound2], after: "round 2 of 3")
        var c = board()
        c.apply(.setNext(rowLast), now: s(0))
        c.apply(.log, now: s(10))
        XCTAssertEqual(c.display(now: s(11))?.label, "Rest")
        // a timed exercise's turn next: nothing to log, and its name
        let toPlank = NextSet(exercise: "Seated row machine", set: 1, of: 3, weight: 90, reps: 12,
                              label: "Round 1 of 3 · Seated row machine · 90 × 12", rest: 15, then: [], after: "Plank")
        var e = board()
        e.apply(.setNext(toPlank), now: s(0))
        e.apply(.log, now: s(10))
        XCTAssertEqual(e.display(now: s(11))?.label, "Next exercise")
    }

    // MARK: - Kept, and readable by the build before

    func testTheLiveActivitysSavedContentHasNoNewField() throws {
        var b = board()
        b.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        b.apply(pageRest(10, next: "Leg press", nextSet: legPress), now: s(10))
        let d = try XCTUnwrap(b.display(now: s(11)))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: Any])
        let before: Set<String> = ["id", "kind", "label", "next", "endsAt", "countsUpFrom", "progressFrom", "paused", "remaining", "fraction",
                                   "nextEndsAt", "elapsed", "nextSet", "logButton", "betweenSets", "setExercise", "setDetail", "later"]
        XCTAssertTrue(Set(o.keys).isSubset(of: before), "only fields the build before knows: \(Set(o.keys).subtracting(before))")
        XCTAssertEqual(o["label"] as? String, "Next exercise", "the words ride in the label the build before already shows")
        XCTAssertEqual(try JSONDecoder().decode(TimerDisplay.self, from: JSONEncoder().encode(d)), d)
    }

    func testWhatWasLoggedIsKeptAndReadsBack() {
        var b = board()
        b.apply(.setNext(press(4, then: [])), now: s(0))
        b.apply(.log, now: s(10))
        let back = TimerBoard.restored(from: TimerBoard.Snapshot.decode(b.snapshot.encoded()), now: s(30))
        XCTAssertEqual(back, b, "the same board after iOS ended the app")
        XCTAssertEqual(back.display(now: s(31))?.label, "Next exercise")
        // a copy saved by the build before has neither field: it reads, and the rest is "Rest" until something's logged
        let old = TimerBoard.Snapshot.decode(Data(#"{"workoutTitle":"Upper A","workoutStartedAt":0}"#.utf8))
        XCTAssertNotNil(old)
        XCTAssertNil(old?.loggedExercise)
        XCTAssertNil(old?.loggedLastSet)
        // two boards that differ only in what was logged aren't the same
        var other = b
        other.loggedExercise = "Leg press"
        XCTAssertNotEqual(other, b)
    }

    func testTheWorkoutsEndForgetsIt() {
        var b = board()
        b.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        b.apply(.workoutFinish(WorkoutSummary(mins: 40, exercises: 5, sets: 18, steps: 0)), now: s(20))
        XCTAssertNil(b.loggedExercise)
        XCTAssertFalse(b.loggedLastSet)
    }

    func testSetLoggedReadsItsExercise() {
        func read(_ s: String) -> BridgeMessage? { BridgeMessage.decode(Data(s.utf8)) }
        XCTAssertEqual(read(#"{"type":"set.logged","exercise":"Chest press machine"}"#), .setLogged(exercise: "Chest press machine"))
        XCTAssertEqual(read(#"{"type":"set.logged","exercise":" Leg press ","warm":true}"#), .setLogged(exercise: "Leg press"), "a warm-up set too")
        XCTAssertEqual(read(#"{"type":"set.logged"}"#), .setLogged(exercise: nil), "an older page")
        XCTAssertEqual(read(#"{"type":"set.logged","exercise":7}"#), .setLogged(exercise: nil))
        XCTAssertEqual(read(#"{"type":"set.logged","exercise":""}"#), .setLogged(exercise: nil))
        // a set.logged with no name doesn't forget the last one
        var b = board()
        b.apply(.setLogged(exercise: "Chest press machine"), now: s(10))
        b.apply(.setLogged(exercise: nil), now: s(11))
        XCTAssertEqual(b.loggedExercise, "Chest press machine")
    }
}
