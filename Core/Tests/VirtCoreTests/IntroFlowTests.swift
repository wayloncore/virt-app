import XCTest
@testable import VirtCore

/// The video intro's order of events: launch clip, lock screen, unlock clip, Training.
final class IntroFlowTests: XCTestCase {
    func testLaunchThenLockThenUnlock() {
        var f = IntroFlow(reduceMotion: false)
        XCTAssertEqual(f.stage, .launch)
        XCTAssertFalse(f.showsUnlockButton, "no button over the launch clip")
        f.launchEnded()
        XCTAssertEqual(f.stage, .lock, "the launch clip ends on the lock screen")
        XCTAssertTrue(f.showsUnlockButton)
        f.unlocked()
        XCTAssertEqual(f.stage, .unlock)
        XCTAssertTrue(f.playingOut)
        XCTAssertFalse(f.showsUnlockButton)
        f.unlockEnded()
        XCTAssertEqual(f.stage, .done)
        XCTAssertFalse(f.playingOut)
    }

    func testUnlockedBeforeTheLaunchClipEnds() {
        var f = IntroFlow(reduceMotion: false)
        f.unlocked()
        XCTAssertEqual(f.stage, .launch, "the launch clip finishes its landing first")
        XCTAssertTrue(f.hurrying)
        XCTAssertTrue(f.playingOut)
        XCTAssertFalse(f.showsUnlockButton)
        f.launchEnded()
        XCTAssertEqual(f.stage, .unlock, "then straight into the unlock clip, no lock screen")
        XCTAssertFalse(f.hurrying)
        f.unlockEnded()
        XCTAssertEqual(f.stage, .done)
    }

    func testATapSkipsToTheLockScreen() {
        var f = IntroFlow(reduceMotion: false)
        f.skip()
        XCTAssertEqual(f.stage, .lock)
        f.skip()
        XCTAssertEqual(f.stage, .lock, "a skip on the lock screen does nothing")
    }

    func testReduceMotionHasNoClips() {
        var f = IntroFlow(reduceMotion: true)
        XCTAssertEqual(f.stage, .lock, "straight to the lock screen")
        f.unlocked()
        XCTAssertEqual(f.stage, .done, "straight to Training")
        f.relocked()
        XCTAssertEqual(f.stage, .lock)
        f.unlocked()
        XCTAssertEqual(f.stage, .done)
    }

    func testRelockShowsTheLockScreenWithNoLaunchClip() {
        var f = IntroFlow(reduceMotion: false)
        f.launchEnded(); f.unlocked(); f.unlockEnded()
        f.relocked()
        XCTAssertEqual(f.stage, .lock)
        f.unlocked()
        XCTAssertEqual(f.stage, .unlock, "the unlock clip still plays")
    }

    func testGoingAwayMidClip() {
        var f = IntroFlow(reduceMotion: false)
        f.interrupted(locked: true)
        XCTAssertEqual(f.stage, .lock, "the launch clip doesn't resume; the lock screen is there")

        var g = IntroFlow(reduceMotion: false)
        g.launchEnded(); g.unlocked()
        g.interrupted(locked: false)
        XCTAssertEqual(g.stage, .done, "already unlocked: straight to Training")

        var h = IntroFlow(reduceMotion: false)
        h.unlocked()
        h.interrupted(locked: false)
        XCTAssertEqual(h.stage, .done)
        XCTAssertFalse(h.hurrying)

        var i = IntroFlow(reduceMotion: false)
        i.launchEnded()
        i.interrupted(locked: true)
        XCTAssertEqual(i.stage, .lock, "nothing playing: no change")
    }

    func testUnlockEndedOnlyEndsTheUnlockClip() {
        var f = IntroFlow(reduceMotion: false)
        f.unlockEnded()
        XCTAssertEqual(f.stage, .launch)
    }
}
