import XCTest
@testable import VirtCore

/// The video intro's order of events with no lock (Nov 28): launch clip, unlock clip, Training. Nothing waits for Face
/// ID or the passcode.
final class IntroFlowTests: XCTestCase {
    func testLaunchThenUnlockThenTraining() {
        var f = IntroFlow.atLaunch(liveWorkout: false, reduceMotion: false, sceneRebuilt: false)
        XCTAssertEqual(f.stage, .launch, "a fresh launch plays the launch clip")
        XCTAssertTrue(f.playing)
        f.launchEnded()
        XCTAssertEqual(f.stage, .unlock, "straight on into the unlock clip: nothing to answer on the way")
        XCTAssertTrue(f.playing)
        f.unlockEnded()
        XCTAssertEqual(f.stage, .done, "then Training")
        XCTAssertFalse(f.playing)
        XCTAssertEqual(IntroFlow(), IntroFlow.atLaunch(liveWorkout: false, reduceMotion: false, sceneRebuilt: false))
    }

    func testATapSkipsTheLaunchClip() {
        var f = IntroFlow()
        f.skip()
        XCTAssertEqual(f.stage, .unlock, "the launch clip's last frame, and the unlock clip from there")
        f.skip()
        XCTAssertEqual(f.stage, .unlock, "a tap during the unlock clip does nothing")
        f.unlockEnded()
        XCTAssertEqual(f.stage, .done)
    }

    func testNoClipDuringALiveWorkoutWithReduceMotionOrForASceneBuiltAgain() {
        for (live, reduce, rebuilt) in [(true, false, false), (false, true, false), (false, false, true), (true, true, true)] {
            let f = IntroFlow.atLaunch(liveWorkout: live, reduceMotion: reduce, sceneRebuilt: rebuilt)
            XCTAssertEqual(f.stage, .done, "straight into Training: live \(live), Reduce Motion \(reduce), rebuilt \(rebuilt)")
            XCTAssertFalse(f.playing)
        }
    }

    func testGoingAwayMidClipComesBackToTraining() {
        var f = IntroFlow()
        f.interrupted()
        XCTAssertEqual(f.stage, .done, "the launch clip doesn't resume")

        var g = IntroFlow()
        g.launchEnded()
        g.interrupted()
        XCTAssertEqual(g.stage, .done, "nor the unlock clip")

        var h = IntroFlow.atLaunch(liveWorkout: true, reduceMotion: false, sceneRebuilt: false)
        h.interrupted()
        XCTAssertEqual(h.stage, .done, "already in Training: no change")
    }

    func testEachEndOnlyEndsItsOwnClip() {
        var f = IntroFlow()
        f.unlockEnded()
        XCTAssertEqual(f.stage, .launch, "the unlock clip's end can't cut the launch clip short")
        var d = IntroFlow.atLaunch(liveWorkout: false, reduceMotion: true, sceneRebuilt: false)
        d.launchEnded()
        XCTAssertEqual(d.stage, .done, "a late end of a clip never brings one back")
    }

    func testTheStagesTheTestBuildReports() {
        XCTAssertEqual([IntroFlow.Stage.launch, .unlock, .done].map(\.rawValue), ["launch", "unlock", "done"])
    }
}
