import XCTest
@testable import VirtCore

/// The messages exactly as the website's bridge sends them (docs/kinetic/bridge.md, tests/kinetic-bridge.test.mjs).
final class BridgeMessageTests: XCTestCase {
    func read(_ json: String) -> BridgeMessage? { BridgeMessage.decode(Data(json.utf8)) }

    func testWorkoutStartAndFinish() {
        XCTAssertEqual(read(#"{"type":"workout.start","title":"Legs A"}"#), .workoutStart(title: "Legs A"))
        XCTAssertEqual(read(#"{"type":"workout.finish","summary":{"mins":42,"exercises":5,"sets":17,"steps":0}}"#),
                       .workoutFinish(WorkoutSummary(mins: 42, exercises: 5, sets: 17, steps: 0)))
        XCTAssertEqual(read(#"{"type":"workout.finish","summary":{"mins":null,"exercises":0,"sets":0,"steps":2}}"#),
                       .workoutFinish(WorkoutSummary(mins: nil, exercises: 0, sets: 0, steps: 2)))
        XCTAssertEqual(read(#"{"type":"workout.close"}"#), .workoutClose)
    }

    func testRestStart() {
        let m = read(#"{"type":"timer.start","id":"rest:1763373600000","kind":"rest","label":"Rest","endsAt":1763373645000,"startedAt":1763373600000,"next":{"label":"set 2 of Plank"}}"#)
        XCTAssertEqual(m, .timerStart(TimerStart(id: "rest:1763373600000", kind: .rest, label: "Rest",
                                                 endsAt: Date(timeIntervalSince1970: 1_763_373_645), startedAt: Date(timeIntervalSince1970: 1_763_373_600),
                                                 next: "set 2 of Plank")))
    }

    func testStopwatchHoldHasNoEnd() {
        guard case .timerStart(let s)? = read(#"{"type":"timer.start","id":"hold:1","kind":"hold","label":"Plank","endsAt":null,"startedAt":1000,"next":{"label":"Stop and log"}}"#) else {
            return XCTFail("not a start")
        }
        XCTAssertNil(s.endsAt)
        XCTAssertEqual(s.kind, .hold)
        XCTAssertEqual(s.next, "Stop and log")
    }

    func testIntervalKindAndUpcoming() {
        guard case .timerStart(let s)? = read(#"{"type":"timer.start","id":"int:5:0","kind":"interval-rest","label":"Recovery · round 1 of 6","endsAt":20000,"startedAt":5000,"next":{"label":"Work, round 2 of 6"},"upcoming":[{"id":"int:5:2","kind":"work","label":"Work · round 2 of 6","endsAt":50000},{"kind":"work"}]}"#) else {
            return XCTFail("not a start")
        }
        XCTAssertEqual(s.kind, .intervalRest)
        XCTAssertEqual(s.upcoming, [Step(id: "int:5:2", kind: .work, label: "Work · round 2 of 6", endsAt: Date(timeIntervalSince1970: 50))],
                       "a step with no id is dropped")
    }

    func testPauseResumeCancelEnd() {
        XCTAssertEqual(read(#"{"type":"timer.pause","id":"rest:1","remaining":35000}"#), .timerPause(id: "rest:1", remaining: 35))
        XCTAssertEqual(read(#"{"type":"timer.pause","id":"hold:1","remaining":null}"#), .timerPause(id: "hold:1", remaining: nil))
        XCTAssertEqual(read(#"{"type":"timer.resume","id":"rest:1","endsAt":55000}"#), .timerResume(id: "rest:1", endsAt: Date(timeIntervalSince1970: 55)))
        XCTAssertEqual(read(#"{"type":"timer.cancel","id":"rest:1"}"#), .timerCancel(id: "rest:1"))
        XCTAssertEqual(read(#"{"type":"timer.end","id":"rest:1"}"#), .timerEnd(id: "rest:1"))
    }

    func testUnknownAndBroken() {
        XCTAssertEqual(read(#"{"type":"timer.lap","id":"x"}"#), .unknown(type: "timer.lap"), "a newer page's message is skipped, not an error")
        XCTAssertNil(read(#"{"id":"x"}"#))
        XCTAssertNil(read(#"{"type":"timer.end"}"#))
        XCTAssertNil(read("not json"))
        XCTAssertEqual(read(#"{"type":"timer.start","id":"rest:1","kind":"sprint","endsAt":1000,"startedAt":0,"next":{"label":"x"},"extra":true}"#).map { m -> TimerKind in
            if case .timerStart(let s) = m { return s.kind }; return .rest
        }, .other)
    }

    func testFromWebKitObject() {
        let obj: [String: Any] = ["type": "timer.resume", "id": "rest:1", "endsAt": 55000]
        XCTAssertEqual(BridgeMessage.decode(object: obj), .timerResume(id: "rest:1", endsAt: Date(timeIntervalSince1970: 55)))
        XCTAssertNil(BridgeMessage.decode(object: "a string"))
    }

    func testCommandScript() {
        XCTAssertEqual(TimerCommand.add15.script, "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: 'add15' }));")
        XCTAssertEqual(Set(TimerCommand.allCases.map(\.rawValue)), ["skip", "add15", "minus15", "pause", "resume"], "the page's COMMANDS")
    }

    func testClock() {
        XCTAssertEqual(TimerDisplay.clock(45), "0:45")
        XCTAssertEqual(TimerDisplay.clock(44.2), "0:45")
        XCTAssertEqual(TimerDisplay.clock(0), "0:00")
        XCTAssertEqual(TimerDisplay.clock(-3), "0:00")
        XCTAssertEqual(TimerDisplay.clock(725), "12:05")
    }

    func testDisplayRoundTripsAndReadsOlderShape() throws {
        let d = TimerDisplay(id: "rest:1", kind: .rest, label: "Rest", next: "set 2", endsAt: Date(timeIntervalSince1970: 100), progressFrom: Date(timeIntervalSince1970: 55))
        let back = try JSONDecoder().decode(TimerDisplay.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
        // the first shape, with only the fields every version has: still reads
        let old = #"{"id":"rest:1","kind":"rest","label":"Rest","next":"x","paused":false}"#
        XCTAssertNoThrow(try JSONDecoder().decode(TimerDisplay.self, from: Data(old.utf8)))
    }
}
