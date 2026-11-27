import XCTest
@testable import VirtCore

/// The zero sound with the phone locked and no notification (Tyler, Nov 27): when the sound keeper runs, which zeros
/// it plays and when, and that no timer notification is left waiting.
final class SoundKeeperTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_021_200)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }

    func resting(_ len: TimeInterval = 90) -> TimerBoard {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Legs A"), now: s(0))
        b.apply(.timerStart(TimerStart(id: "rest:0", kind: .rest, label: "Rest", endsAt: s(len), startedAt: s(0), next: "set 2 of Plank")), now: s(0))
        return b
    }

    func testRunsOnlyDuringAWorkoutWithVirtAwayAndSoundsOn() {
        let b = resting()
        XCTAssertTrue(SoundKeeper.shouldRun(soundsOn: true, away: true, board: b, live: true, now: s(5)))
        XCTAssertTrue(SoundKeeper.shouldRun(soundsOn: true, away: true, board: b, live: false, now: s(5)),
                      "a running countdown is enough, whatever the page last said")
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: false, away: true, board: b, live: true, now: s(5)), "Sounds off: no keeper")
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: true, away: false, board: b, live: true, now: s(5)),
                       "Virt on the screen plays its own sounds, as before")
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: true, away: true, board: TimerBoard(), live: false, now: s(5)), "no workout")
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: true, away: true, board: TimerBoard(), live: true, now: s(5)),
                       "the page's word alone, with nothing on the board, isn't a workout")
    }

    func testBetweenSetsAndPausedItKeepsGoingWhileTheWorkoutIsLive() {
        var b = resting()
        b.apply(.pause, now: s(10))
        XCTAssertTrue(b.alerts(now: s(11)).isEmpty)
        XCTAssertTrue(SoundKeeper.shouldRun(soundsOn: true, away: true, board: b, live: true, now: s(11)), "paused mid-workout")
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: true, away: true, board: b, live: false, now: s(11)),
                       "the page said the workout's over")
        // the rest ended; between sets, so a Log set from the lock screen starts a rest that sounds
        var c = resting(30)
        c.apply(.timerEnd(id: "rest:0"), now: s(30))
        XCTAssertTrue(SoundKeeper.shouldRun(soundsOn: true, away: true, board: c, live: true, now: s(60)))
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: true, away: true, board: c, live: true, now: s(30 + TimerBoard.quietLimit + 1)),
                       "quiet past the limit: stops, never outside a workout")
        c.apply(.workoutClose, now: s(70))
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: true, away: true, board: c, live: false, now: s(71)), "workout over")
    }

    func testCuesStartEarlyByTheirLeadIn() {
        let b = resting()
        let chime = SoundKeeper.cues(board: b, style: .chime, now: s(5))
        XCTAssertEqual(chime.count, 1)
        XCTAssertEqual(chime[0].cue, .go)
        XCTAssertEqual(chime[0].file, SoundStyle.startFile)
        XCTAssertEqual(chime[0].zeroAt, s(90))
        XCTAssertEqual(chime[0].playAt, s(90 - SoundStyle.startLead), "the green light starts 1.2 s early")
        XCTAssertEqual(chime[0].key, "virt.timer.rest:0@\(s(90).timeIntervalSince1970)")
        let classic = SoundKeeper.cues(board: b, style: .classic, now: s(5))
        XCTAssertEqual(classic[0].playAt, s(90), "Classic's chime is on the zero")
        XCTAssertEqual(classic[0].file, "virt-chime.wav")
        // inside the lead-in: kept, to play at once
        XCTAssertEqual(SoundKeeper.cues(board: b, style: .chime, now: s(89.5)).count, 1)
        XCTAssertTrue(SoundKeeper.cues(board: b, style: .chime, now: s(91)).isEmpty)
    }

    /// A tone style (Nov 27): the keeper plays its one tone at both zeros, right on the zero (no lead).
    func testAToneStyleThroughTheKeeper() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Intervals"), now: s(0))
        b.apply(.timerStart(TimerStart(id: "int:0", kind: .work, label: "Work", endsAt: s(30), startedAt: s(0), next: "Rest", upcoming: [
            Step(id: "int:1", kind: .intervalRest, label: "Rest", endsAt: s(45)),
        ])), now: s(0))
        let cues = SoundKeeper.cues(board: b, style: .questJingle, now: s(1))
        XCTAssertEqual(cues.map(\.cue), [.rest, .go])
        XCTAssertEqual(cues.map(\.file), ["virt-quest-jingle-zero.caf", "virt-quest-jingle-zero.caf"])
        XCTAssertEqual(cues.map(\.playAt), [s(30), s(45)], "on the zero: the 3-2-1 ticks are its lead-in")
        // Digital's work-ends is the rising trill now
        XCTAssertEqual(SoundKeeper.cues(board: b, style: .digital, now: s(1)).first?.file, "virt-digital-up.caf")
    }

    func testEveryUpcomingZeroIsAhead() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Intervals"), now: s(0))
        b.apply(.timerStart(TimerStart(id: "int:0", kind: .work, label: "Work", endsAt: s(30), startedAt: s(0), next: "Rest", upcoming: [
            Step(id: "int:1", kind: .intervalRest, label: "Rest", endsAt: s(45)),
            Step(id: "int:2", kind: .work, label: "Work", endsAt: s(75)),
        ])), now: s(0))
        let cues = SoundKeeper.cues(board: b, style: .digital, now: s(1))
        XCTAssertEqual(cues.map(\.zeroAt), [s(30), s(45), s(75)])
        XCTAssertEqual(cues.map(\.cue), [.rest, .go, .rest])
        XCTAssertEqual(cues[1].playAt, s(45 - SoundStyle.startLead))
        // pause: nothing ahead; skip forward to the next step: its zeros only
        var p = b
        p.apply(.pause, now: s(10))
        XCTAssertTrue(SoundKeeper.cues(board: p, style: .digital, now: s(10)).isEmpty)
    }

    func testNoTimerNotificationIsLeftWaiting() {
        let pending = ["virt.timer.rest:0", "virt.reminder.2026-11-28", "virt.timer.int:1", "something-else"]
        XCTAssertEqual(TimerAlerts.pendingToRemove(pending), ["virt.timer.rest:0", "virt.timer.int:1"], "reminders stay")
        XCTAssertTrue(SoundKeeper.State.on.covers)
        XCTAssertFalse(SoundKeeper.State.interrupted.covers)
        XCTAssertFalse(SoundKeeper.State.failed.covers)
    }

    /// The pieces the app needs for it, read from the source (a Mac build is what proves they compile).
    func testTheAppHoldsAMixablePlaybackSessionOnlyForTheKeeper() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let keeper = try String(contentsOf: root.appendingPathComponent("App/BackgroundSound.swift"), encoding: .utf8)
        XCTAssertTrue(keeper.contains("setCategory(.playback, mode: .default, options: [.mixWithOthers])"), "his music keeps playing")
        XCTAssertFalse(keeper.contains(".duckOthers"), "no ducking while locked")
        XCTAssertTrue(keeper.contains("setCategory(.ambient, options: [.mixWithOthers])"), "handed back as ambient")
        XCTAssertTrue(keeper.contains("interruptionNotification") && keeper.contains("routeChangeNotification"))
        let spec = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(spec.contains("UIBackgroundModes: [audio]"))
        let engine = try String(contentsOf: root.appendingPathComponent("App/Engine.swift"), encoding: .utf8)
        XCTAssertFalse(engine.contains("UNMutableNotificationContent"), "a timer zero never schedules a notification (Tyler, Nov 27)")
        XCTAssertFalse(engine.contains("requestAuthorization"), "a workout never asks for notification permission")
        let reminders = try String(contentsOf: root.appendingPathComponent("App/Reminders.swift"), encoding: .utf8)
        XCTAssertTrue(reminders.contains("requestAuthorization"), "only turning on the reminders asks")
        XCTAssertTrue(engine.contains("BackgroundSound.shared.covers(key)"), "the app's own chime never doubles the keeper's")
    }
}
