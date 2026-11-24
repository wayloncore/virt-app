import XCTest

/// Virt in the iPhone simulator: the Face ID lock (with the test build answering for Face ID), the studio's sign-in
/// opens inside the app, the offline screen and Retry, and the bridge end to end with a stand-in page (the real Training page is behind the sign-in, which a GitHub Mac can't
/// pass): a rest's alert, the screen kept on, the Live Activity, and a lock-screen button reaching the page.
final class VirtUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Opens Virt. The test build answers for Face ID (`-uitest-skip-faceid`: Unlock works; `-uitest-faceid-fails`:
    /// it never does), and by default this taps Unlock, the way Tyler would.
    /// `args` adds the test build's door: `-uitest-door-none` (the first screen) or `-uitest-door-friend`; Tyler's
    /// otherwise.
    func launch(env: [String: String] = [:], unlock: Bool = true, faceIDFails: Bool = false, args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset", faceIDFails ? "-uitest-faceid-fails" : "-uitest-skip-faceid"] + args
        app.launchEnvironment = env
        app.launch()
        if unlock {
            let button = app.buttons["unlock"]
            XCTAssertTrue(button.waitForExistence(timeout: 15), "the lock screen shows first")
            button.tap()
            XCTAssertTrue(app.otherElements["lock-screen"].waitForNonExistence(timeout: 5), "Unlock opens the app")
            XCTAssertTrue(app.otherElements["unlocking"].waitForNonExistence(timeout: 10), "the unlock clip ends in Training")
        }
        return app
    }

    /// Where the intro is, as the test build's lock screen says ("launch", "lock", "unlock" or "done").
    func introStage(_ app: XCUIApplication) -> String {
        let t = app.staticTexts["intro-stage"]
        return t.exists ? String(t.label.dropFirst("intro ".count)) : "none"
    }

    func waitIntro(_ app: XCUIApplication, _ stage: String, _ timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if introStage(app) == stage { return true }
            usleep(100_000)
        }
        return false
    }

    /// True while Training's web view can be seen and touched.
    func studioShows(_ app: XCUIApplication) -> Bool {
        let web = app.webViews["studio"]
        return web.exists && web.isHittable
    }

    func status(_ app: XCUIApplication) -> String {
        let s = app.staticTexts["virt-status"]
        return s.exists ? s.label : ""
    }

    func waitStatus(_ app: XCUIApplication, contains text: String, _ timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if status(app).contains(text) { return true }
            usleep(300_000)
        }
        return false
    }

    /// When the running timer reaches zero, as the status line says ("ends at 1794933871", epoch seconds).
    func endsAt(_ app: XCUIApplication) -> Int? {
        let t = status(app)
        guard let r = t.range(of: #"ends at \d+"#, options: .regularExpression) else { return nil }
        return Int(t[r].dropFirst("ends at ".count))
    }

    /// Saves a screenshot as <name>.png in ~/virt-shots on the Mac (the workflow prints them into its log).
    func shot(_ name: String, _ s: XCUIScreenshot = XCUIScreen.main.screenshot()) {
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSTemporaryDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent("virt-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The notification permission prompt, if it's up.
    func allowAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    /// Opening the app goes to studio Training; signed out, Cloudflare Access's sign-in shows inside the app.
    func testOpensTheStudioSignIn() {
        let app = launch()
        XCTAssertTrue(app.webViews["studio"].waitForExistence(timeout: 15))
        let reached = waitStatus(app, contains: "cloudflareaccess.com", 40) || waitStatus(app, contains: "host studio.tyleralocke.com", 5)
        sleep(4)  // let the page draw
        shot("signin")
        XCTAssertTrue(reached, "the sign-in opened inside the app: \(status(app))")
        XCTAssertFalse(status(app).contains("offline screen"), "no offline screen: \(status(app))")
        XCTAssertEqual(app.state, .runningForeground, "nothing was sent to Safari")
    }

    // MARK: - Training for friends (#578, part 2)

    /// A new phone (#732): one way in, Sign in with Apple on the first screen (a simulator can't finish
    /// it). The studio's sign-in is nowhere, even on a phone that used it.
    func testOneSignInFirst() {
        let app = launch(args: ["-uitest-door-none", "-uitest-studio-used"])
        let apple = app.buttons["apple-sign-in"]
        XCTAssertTrue(apple.waitForExistence(timeout: 15) || app.buttons["Sign in with Apple"].exists, "the first screen: Sign in with Apple (a simulator can't finish it)")
        XCTAssertTrue(app.staticTexts["welcome-line"].exists)
        XCTAssertFalse(app.buttons["get-started"].exists, "no step before Sign in with Apple")
        XCTAssertFalse(app.buttons["age-yes"].exists, "no 13+ question: the first screen says 13 and up")
        XCTAssertFalse(app.staticTexts["Training for friends"].exists, "no door choice")
        sleep(1)
        shot("welcome")

        XCTAssertFalse(app.buttons["door-tyler"].exists, "the studio's sign-in is gone from Virt, even on a phone that used it")
    }

    /// Tyler's phone from before Apple sign-in (still set to the studio's door): the first screen, and nothing about
    /// the studio. It never opens Cloudflare by itself.
    func testAStudioPhoneIsOfferedAppleOnce() {
        let app = launch(args: ["-uitest-apple-not-asked"])
        XCTAssertTrue(app.staticTexts["welcome-line"].waitForExistence(timeout: 15), "the first screen, not the studio's sign-in")
        XCTAssertTrue(app.buttons["apple-sign-in"].exists || app.buttons["Sign in with Apple"].exists, "Sign in with Apple, right there")
        XCTAssertFalse(app.buttons["door-tyler"].exists, "no studio sign-in anywhere")
        XCTAssertFalse(status(app).contains("cloudflareaccess.com"), status(app))
        sleep(1)
        shot("apple-once")
    }

    /// Tyler's phone once his Apple ID has opened his Training: the studio's sign-in is never offered again (it's
    /// his alone, and he's past it). The first screen is his VIRT word, one line, and Sign in with Apple.
    func testNoStudioSignInOnceAppleOpenedHisTraining() {
        let app = launch(args: ["-uitest-door-none", "-uitest-studio-used", "-uitest-owner-opened"])
        XCTAssertTrue(app.staticTexts["welcome-line"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["welcome-line"].label, "Strength is a virtue. Build it daily.")
        XCTAssertTrue(app.images["virt-word"].exists, "his VIRT word, from the intro's own frame")
        XCTAssertTrue(app.buttons["apple-sign-in"].exists || app.buttons["Sign in with Apple"].exists)
        XCTAssertFalse(app.buttons["door-tyler"].exists, "no studio sign-in once Apple has opened his Training")
        sleep(1)
        shot("first-screen")
    }

    /// The second way in: "Try a workout" under Sign in with Apple opens the guest page with no sign-in and no
    /// session handed over (the stand-in page says which). Nothing is saved, so the next launch asks again.
    func testTryAWorkoutOpensWithNoAccount() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.friendPage], args: ["-uitest-door-none"])
        let tryIt = app.buttons["try-workout"]
        XCTAssertTrue(tryIt.waitForExistence(timeout: 15), "Try a workout, on the first screen")
        XCTAssertEqual(tryIt.label, "Try a workout")
        sleep(1)
        shot("first-screen-try")
        tryIt.tap()
        XCTAssertTrue(waitStatus(app, contains: "door friend guest", 15), status(app))
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), "the bridge works for a guest: \(status(app))")
        XCTAssertFalse(web.staticTexts["session: handed over"].exists, "no session: a guest has no account")
        XCTAssertFalse(app.buttons["apple-sign-in"].exists, "the first screen is gone")
    }

    /// You's "Account and app settings" row (the page's `settings` message) opens Virt's own settings sheet, where
    /// sign out and Delete account are: one tap from inside the app, not only from the Home Screen icon's menu.
    func testThePageOpensVirtsSettings() {
        let token = "uitestfriendsession0123456789"
        let app = launch(env: ["VIRT_TEST_HTML": Self.friendPage, "VIRT_FRIEND_TOKEN": token], args: ["-uitest-door-friend"])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), status(app))
        web.buttons["Account and app settings"].tap()
        XCTAssertTrue(app.staticTexts["signed-in-as"].waitForExistence(timeout: 8) || app.staticTexts["Signed in"].waitForExistence(timeout: 2),
                      "Virt's settings sheet is up")
        XCTAssertTrue(app.buttons["Delete account"].waitForExistence(timeout: 5), "Delete account is there, one tap from the page")
        sleep(1)
        shot("settings-from-page")
    }

    /// A friend's phone (never used the studio): no studio sign-in anywhere on the first screen.
    func testAFriendsPhoneHasNoStudioDoor() {
        let app = launch(args: ["-uitest-door-none"])
        XCTAssertTrue(app.staticTexts["welcome-line"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["apple-sign-in"].waitForExistence(timeout: 5) || app.buttons["Sign in with Apple"].exists)
        XCTAssertFalse(app.buttons["door-tyler"].exists, "no studio sign-in on a friend's phone")
    }

    /// A friend signed in (a made-up session): train.time2play.live gets the session before its scripts run, the
    /// kinetic bridge works there the same (a rest, its alert at zero, the Live Activity), and the page's own
    /// "Sign out here" signs Virt out too, back to the first screen. The stand-in page talks like the friends' page
    /// (the real one is a 404 until Tyler approves the training-friends switch).
    func testFriendDoorOpensTraining() {
        let token = "uitestfriendsession0123456789"
        let app = launch(env: ["VIRT_TEST_HTML": Self.friendPage, "VIRT_FRIEND_TOKEN": token], args: ["-uitest-door-friend"])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["session: handed over"].waitForExistence(timeout: 20), "the page got the session: \(status(app))")
        XCTAssertTrue(web.staticTexts["handler: yes"].exists, "the kinetic bridge on train.time2play.live")
        XCTAssertTrue(waitStatus(app, contains: "door friend"), status(app))
        XCTAssertTrue(status(app).contains("host train.time2play.live"), status(app))
        sleep(2)
        shot("friend-today")

        web.buttons["Start rest"].tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), status(app))
        XCTAssertTrue(status(app).contains("alerts 1"), "the alert at zero: \(status(app))")
        XCTAssertTrue(status(app).contains("workout Full body A"), status(app))

        web.buttons["Sign out here"].tap()
        XCTAssertTrue(app.staticTexts["welcome-line"].waitForExistence(timeout: 10), "signed out: the first screen")
    }

    /// With no way to reach the studio: the plain offline screen, and Retry.
    func testOfflineScreenAndRetry() {
        let app = launch(env: ["VIRT_START_URL": "https://virt-offline-check.invalid/"])
        let retry = app.buttons["retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "the offline screen shows: \(status(app))")
        XCTAssertTrue(app.staticTexts["Can't reach the studio"].exists)
        shot("offline")
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "Retry tries again and lands on the same screen while still offline")
    }

    /// The bridge end to end, with a stand-in page that talks exactly like studio Training.
    func testBridgeTimerLiveActivityAndButtons() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), "the page sees the kinetic handler")
        XCTAssertTrue(waitStatus(app, contains: "awake off"), status(app))

        web.buttons["Start rest"].tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), status(app))
        XCTAssertTrue(status(app).contains("alerts 1"), "one alert at the exact zero: \(status(app))")
        XCTAssertTrue(status(app).contains("awake on"), "the screen stays on: \(status(app))")
        XCTAssertTrue(status(app).contains("workout Bridge test"), status(app))
        shot("bridge-rest")

        // a lock-screen button: the app applies it and hands it to the page, which answers with the new end
        let before = endsAt(app) ?? 0
        app.buttons["dbg-add15"].tap()
        XCTAssertTrue(web.staticTexts["command: add15"].waitForExistence(timeout: 10), "the page got kinetic:command")
        XCTAssertTrue(waitStatus(app, contains: "ends at \(before + 15)", 5), "+15 moved the end 15 s: \(before), then \(status(app))")
        app.buttons["dbg-pause"].tap()
        XCTAssertTrue(web.staticTexts["command: pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitStatus(app, contains: "paused"), status(app))
        XCTAssertTrue(status(app).contains("alerts 0"), "no alert while paused: \(status(app))")
        app.buttons["dbg-resume"].tap()
        XCTAssertTrue(waitStatus(app, contains: "running"), status(app))
        let activityOn = status(app).contains("activity on")

        // the Live Activity: the Dynamic Island from the home screen, then the lock-screen view in Notification Center
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("dynamic-island")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7)))
        sleep(3)
        shot("live-activity")
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()

        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 10))
        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer none"), status(app))
        XCTAssertTrue(waitStatus(app, contains: "awake off"), "a saved workout lets the screen sleep: \(status(app))")
        XCTAssertTrue(status(app).contains("alerts 0"), status(app))
        XCTAssertTrue(activityOn, "the Live Activity started")
    }

    // MARK: - Today, reminders, Siri's commands and the set haptic

    /// The page's `today` reaches Virt (status line, shared store), the friendly reminders ask comes once, a logged set
    /// taps, and Siri's two commands reach the page (a rest starts at once and the page takes it over).
    func testTodayRemindersAndCommands() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20))

        web.buttons["Post today"].tap()
        XCTAssertTrue(waitStatus(app, contains: "today Legs A"), status(app))
        let ask = app.buttons["remind-yes"]
        if !ask.waitForExistence(timeout: 10) { shot("reminder-ask-missing") }
        XCTAssertTrue(ask.exists, "the friendly ask, the first time: \(status(app))")
        sleep(1)
        shot("reminder-ask")
        ask.tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "reminders 6") || waitStatus(app, contains: "reminders 7", 5), status(app))
        XCTAssertFalse(status(app).contains("store not saved"), status(app))

        web.buttons["Post done"].tap()
        XCTAssertTrue(waitStatus(app, contains: "today Legs A done"), status(app))
        XCTAssertTrue(waitStatus(app, contains: "reminders 6"), "today's is skipped once done: \(status(app))")
        XCTAssertFalse(ask.exists, "asked once only")

        web.buttons["Log set"].tap()
        XCTAssertTrue(waitStatus(app, contains: "taps 1"), "a light tap for a logged set: \(status(app))")

        app.buttons["dbg-start"].tap()
        XCTAssertTrue(web.staticTexts["command: startToday"].waitForExistence(timeout: 10), status(app))
        app.buttons["dbg-rest"].tap()
        XCTAssertTrue(web.staticTexts["command: rest 90"].waitForExistence(timeout: 10), status(app))
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), "the page's rest took over from Virt's: \(status(app))")
        XCTAssertTrue(status(app).contains("alerts 1"), status(app))
        shot("commands")

        // Virt's settings sheet (the Home Screen quick action and virt://settings open it the same way)
        app.buttons["dbg-settings"].tap()
        let settings = app.buttons["settings-done"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the settings sheet opens")
        sleep(1)
        shot("settings")
        app.swipeUp()
        sleep(1)
        shot("settings-2")
        app.buttons["settings-done"].tap()
    }

    /// The widgets' own views at real size (a UI test can't add a widget to the Home Screen).
    func testWidgetGallery() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset", "-uitest-skip-faceid", "-uitest-widgets"]
        app.launch()
        let unlock = app.buttons["unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 15))
        unlock.tap()
        sleep(2)
        shot("widgets-home")
        app.buttons["Lock"].tap()
        sleep(1)
        shot("widgets-lock")
        app.buttons["StandBy"].tap()
        sleep(1)
        shot("widgets-standby")
        app.buttons["Activity"].tap()
        sleep(1)
        shot("widgets-activity")
        app.swipeUp()
        sleep(1)
        shot("widgets-activity-2")
    }

    /// Log set (wayloncore/tyleralocke#573): the page names the next set, the Live Activity shows it between sets,
    /// and Log set reaches the page, which logs it and starts the rest (shown at once, before the page answers).
    func testLogSetFromTheLockScreen() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), "the page sees the kinetic handler")
        web.buttons["Open exercise"].tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "next Chest press machine · set 2 of 4 · 105 × 10"), status(app))
        XCTAssertTrue(status(app).contains("timer none"), status(app))
        XCTAssertTrue(waitStatus(app, contains: "activity on", 5), "between sets, the activity shows the next set: \(status(app))")
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("logset-island")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7)))
        sleep(3)
        shot("logset-between")
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()

        // Log set (the same path as the Live Activity's button)
        XCTAssertTrue(app.buttons["dbg-log"].waitForExistence(timeout: 10))
        app.buttons["dbg-log"].tap()
        XCTAssertTrue(web.staticTexts["logged: 1"].waitForExistence(timeout: 10), "the page logged the set")
        XCTAssertTrue(web.staticTexts["command: log"].exists)
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), "the page's rest took over: \(status(app))")
        XCTAssertTrue(waitStatus(app, contains: "next Chest press machine · set 3 of 4 · 105 × 10"), status(app))
        XCTAssertTrue(status(app).contains("alerts 1"), status(app))
        XCUIDevice.shared.press(.home)
        sleep(3)
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7)))
        sleep(3)
        shot("logset-resting")
        XCUIDevice.shared.press(.home)
        sleep(1)
        // the Dynamic Island expanded (a long press on it), the rest with the next set under the buttons
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).press(forDuration: 1.2)
        sleep(2)
        shot("logset-island-expanded")
        app.activate()

        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 10))
        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "next none"), status(app))
        XCTAssertTrue(waitStatus(app, contains: "activity off"), status(app))
    }

    /// The video intro's frames, held still (the test build's VIRT_INTRO_AT and VIRT_UNLOCK_AT, seconds into each
    /// clip): the word as the light crosses it, mid-wipe, the V growing, the launch clip's last frame, the lock
    /// screen's still (the same frame), and the unlock clip flying into the V.
    func testIntroFrames() {
        let frames: [(String, [String: String])] = [
            ("intro-1-start", ["VIRT_INTRO_AT": "0.3"]),
            ("intro-2-word", ["VIRT_INTRO_AT": "1.5"]),
            ("intro-3-midwipe", ["VIRT_INTRO_AT": "2.3"]),
            ("intro-4-growing", ["VIRT_INTRO_AT": "2.95"]),
            ("intro-5-end", ["VIRT_INTRO_AT": "\(Self.launchLastFrame)"]),
            ("intro-6-still", ["VIRT_INTRO": "off"]),
            ("unlock-1-start", ["VIRT_UNLOCK_AT": "0"]),
            ("unlock-2-zoom", ["VIRT_UNLOCK_AT": "0.6"]),
            ("unlock-2b-edges", ["VIRT_UNLOCK_AT": "0.9"]),
            ("unlock-3-fly", ["VIRT_UNLOCK_AT": "1.2"]),
            ("unlock-4-past", ["VIRT_UNLOCK_AT": "1.45"]),
        ]
        for (name, env) in frames {
            let app = XCUIApplication()
            app.launchArguments = ["-uitest", "-uitest-reset", "-uitest-faceid-fails"]
            app.launchEnvironment = env.merging(["VIRT_TEST_HTML": Self.page]) { a, _ in a }
            app.launch()
            XCTAssertTrue(app.otherElements["lock-screen"].waitForExistence(timeout: 15), name)
            sleep(2)
            shot(name)
            app.terminate()
        }
    }

    /// Played for real: the launch clip ends by itself on the lock screen (no Unlock button over the clip), Unlock
    /// plays the unlock clip, and it fades into Training.
    func testIntroPlaysIntoTheLockScreenThenTraining() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page], unlock: false)
        XCTAssertTrue(app.otherElements["lock-screen"].waitForExistence(timeout: 15))
        XCTAssertEqual(introStage(app), "launch", "the launch clip plays first")
        XCTAssertFalse(app.buttons["unlock"].exists, "no button over the launch clip")
        XCTAssertTrue(waitIntro(app, "lock", 8), "the launch clip ends on the lock screen: \(introStage(app))")
        let button = app.buttons["unlock"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        sleep(1)
        shot("intro-7-lock")
        button.tap()
        XCTAssertTrue(app.otherElements["unlocking"].waitForExistence(timeout: 3), "the unlock clip plays")
        usleep(700_000)
        shot("unlock-5-live")
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 8), "then Training")
        XCTAssertFalse(app.otherElements["unlocking"].exists)
        XCTAssertTrue(studioShows(app))
        sleep(1)
        shot("unlock-6-training")
    }

    /// A tap skips the launch clip straight to the lock screen.
    func testATapSkipsTheIntro() {
        // the launch clip at a fifth of its speed (about 17 s), so the tap lands during it on a slow simulator
        let app = launch(env: ["VIRT_TEST_HTML": Self.page, "VIRT_INTRO_RATE": "0.2"], unlock: false)
        let skip = app.descendants(matching: .any)["skip-intro"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "the launch clip can be skipped")
        XCTAssertEqual(introStage(app), "launch")
        skip.tap()
        XCTAssertTrue(waitIntro(app, "lock", 1.5), "straight to the lock screen: \(introStage(app))")
        XCTAssertTrue(app.buttons["unlock"].waitForExistence(timeout: 2))
    }

    /// Face ID says yes while the launch clip is still playing: the V lands quickly, the unlock clip plays, then
    /// Training, and the lock screen's button never shows.
    func testUnlockDuringTheIntro() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset", "-uitest-auto-unlock"]
        app.launchEnvironment = ["VIRT_TEST_HTML": Self.page]
        app.launch()
        let web = app.webViews["studio"]
        var sawButton = false
        let end = Date().addingTimeInterval(10)
        while Date() < end, !web.staticTexts["handler: yes"].exists || app.otherElements["unlocking"].exists
                || app.otherElements["lock-screen"].exists {
            if app.buttons["unlock"].exists { sawButton = true }
            usleep(150_000)
        }
        XCTAssertTrue(studioShows(app), "Training, within 10 s of launch")
        // the test build's status line lists the intro's stages: the launch clip, the unlock clip, Training
        XCTAssertTrue(waitStatus(app, contains: "intro launch>unlock>done", 5), "the unlock clip played: \(status(app))")
        XCTAssertFalse(sawButton, "no lock screen on the way")
    }

    /// Reduce Motion: no video. The lock screen's V fades in at once, and Unlock fades straight to Training.
    func testReduceMotionHasNoVideo() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset", "-uitest-skip-faceid", "-uitest-reduce-motion"]
        app.launchEnvironment = ["VIRT_TEST_HTML": Self.page]
        app.launch()
        let button = app.buttons["unlock"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(introStage(app), "lock", "no launch clip")
        sleep(1)
        shot("reduce-motion-lock")
        button.tap()
        XCTAssertFalse(app.otherElements["unlocking"].waitForExistence(timeout: 0.5), "no unlock clip")
        XCTAssertTrue(app.webViews["studio"].staticTexts["handler: yes"].waitForExistence(timeout: 5))
        XCTAssertTrue(studioShows(app))
    }

    /// The launch clip's last frame (seconds in): VIRT_INTRO_AT for the end of the clip. App/Intro/virt-launch.mp4.
    static let launchLastFrame = 3.99

    // MARK: - The Face ID lock

    /// A fresh launch shows the lock screen first, with Training hidden; Unlock shows the page, already loaded.
    func testLockScreenFirstThenUnlock() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page], unlock: false)
        XCTAssertTrue(app.otherElements["lock-screen"].waitForExistence(timeout: 15), "the lock screen shows first")
        let button = app.buttons["unlock"]
        XCTAssertTrue(button.waitForExistence(timeout: 8), "the launch clip ends on Unlock")
        sleep(2)  // the page loads behind the lock
        XCTAssertFalse(studioShows(app), "nothing of Training shows while locked")
        shot("lock")
        button.tap()
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 8), "the unlock clip ends on the page, already loaded")
        XCTAssertFalse(app.otherElements["lock-screen"].exists)
        XCTAssertTrue(studioShows(app))
    }

    /// When Face ID fails or he cancels: still locked, a short note, and Unlock to try again. No way around it.
    func testFailedUnlockStaysLocked() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page], unlock: false, faceIDFails: true)
        let button = app.buttons["unlock"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        let note = app.staticTexts["lock-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "a note says why")
        XCTAssertTrue(note.label.contains("Try again") || note.label.contains("try again"), note.label)
        sleep(1)
        shot("lock-failed")
        XCTAssertTrue(app.otherElements["lock-screen"].exists, "still locked")
        XCTAssertTrue(button.isEnabled, "he can try again")
        button.tap()
        sleep(1)
        XCTAssertTrue(app.otherElements["lock-screen"].exists, "still locked after a second try")
        XCTAssertFalse(studioShows(app))
    }

    /// The app switcher's picture shows the cover, not Training; a quick trip away doesn't ask to unlock again.
    func testAppSwitcherCoverAndAQuickTrip() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20))
        // swipe up from the bottom edge and hold: the app switcher
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.998))
        bottom.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)),
                     withVelocity: .slow, thenHoldForDuration: 1.2)
        sleep(2)
        shot("app-switcher")
        // the simulator's own way in, too: home twice, quickly
        XCUIDevice.shared.press(.home)
        sleep(1)
        XCUIDevice.shared.press(.home)
        usleep(150_000)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("app-switcher-2")
        app.activate()
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 10), "back in Training")
        XCTAssertFalse(app.buttons["unlock"].exists, "a quick trip away doesn't lock")
        XCTAssertTrue(studioShows(app))
    }

    /// With the time away cut to 3 seconds (the test build only): coming back mid-workout never asks; once the
    /// workout is finished, coming back locks it.
    func testLocksAfterTimeAwayButNeverMidWorkout() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page, "VIRT_LOCK_AFTER": "3"])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20))
        web.buttons["Start rest"].tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), status(app))

        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()
        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 10), "mid-workout: straight back in")
        XCTAssertFalse(app.buttons["unlock"].exists, "no unlock mid-workout")

        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer none"), status(app))
        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()
        let button = app.buttons["unlock"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "away long enough with no workout: locked")
        XCTAssertFalse(studioShows(app))
        shot("locked-again")
        XCTAssertEqual(introStage(app), "lock", "locked again: the V lock screen, no launch clip")
        button.tap()
        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 8), "unlocked: the same page, right where it was")
    }

    /// Stands in for train.time2play.live's Today (the friends' Training): its paper look, the session the app hands
    /// over (window.T2P_SESSION, read once and deleted, as the page's client.js does), the kinetic bridge, and the
    /// page's own "Sign out here" (data-sign-out).
    static let friendPage = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#f4ede1"></head>
    <body style="font: 17px -apple-system; margin: 0; padding: 20px 18px; background: #f4ede1; color: #2a1d12">
    <p style="margin: 0; font-size: 13px; letter-spacing: .08em; text-transform: uppercase; color: #7a2232">Week 1 · Today</p>
    <h1 style="font: italic 700 34px Georgia, serif; margin: 6px 0 4px">Full body A</h1>
    <p style="margin: 0 0 16px; color: #6b5a4a">5 moves · about 45 minutes. This week finds your weights: one you could lift about 12 times.</p>
    <ol style="padding-left: 22px; line-height: 1.9; margin: 0 0 18px">
    <li>Goblet squat · 3 × 8–12</li><li>Dumbbell bench press · 3 × 8–12</li><li>Seated cable row · 3 × 8–12</li>
    <li>Romanian deadlift · 3 × 8–12</li><li>Plank · 3 × 30 s</li></ol>
    <p><button onclick="go()" style="font-size: 18px; padding: 10px 18px; border: 0; border-radius: 12px; background: #7a2232; color: #fff">Start rest</button>
    <button onclick="fin()" style="font-size: 18px; padding: 10px 18px">Finish</button></p>
    <p><button onclick="post({ type: 'settings' })" style="font-size: 16px">Account and app settings</button></p>
    <p><button data-sign-out onclick="out()" style="font-size: 16px">Sign out here</button></p>
    <p id="session" style="font-size: 13px; color: #6b5a4a">session: none</p>
    <p id="has" style="font-size: 13px; color: #6b5a4a">handler: no</p>
    <script>
    const t = window.T2P_SESSION;
    try { delete window.T2P_SESSION; } catch (e) {}
    document.getElementById('session').textContent = typeof t === 'string' && /^[A-Za-z0-9]{16,200}$/.test(t) && window.T2P_SESSION === undefined ? 'session: handed over' : 'session: none';
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kinetic;
    document.getElementById('has').textContent = h ? 'handler: yes' : 'handler: no';
    const post = (m) => h && h.postMessage(m);
    let start = 0, end = 0;
    function go() { start = Date.now(); end = start + 90000; post({ type: 'workout.start', title: 'Full body A' });
      post({ type: 'timer.start', id: 'rest:' + start, kind: 'rest', label: 'Rest', endsAt: end, startedAt: start }); }
    function fin() { post({ type: 'timer.cancel', id: 'rest:' + start }); post({ type: 'workout.finish', summary: { mins: 1, exercises: 1, sets: 1, steps: 0 } }); }
    function out() { document.getElementById('session').textContent = 'signed out'; }
    </script></body></html>
    """

    /// Talks to the app the way studio Training does (docs/kinetic/bridge.md on the website).
    static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#f4ede1"></head>
    <body style="font: 18px -apple-system; padding: 16px; background: #f4ede1; color: #2a1d12">
    <h2>Bridge check</h2>
    <p id="has">handler: no</p>
    <p><button onclick="go()" style="font-size: 20px">Start rest</button> <button onclick="fin()" style="font-size: 20px">Finish</button></p>
    <p><button onclick="today(false)">Post today</button> <button onclick="today(true)">Post done</button> <button onclick="post({ type: 'set.logged' })">Log set</button></p>
    <p><button onclick="openEx()">Open exercise</button></p>
    <p id="cmd">command: none</p>
    <p id="logged">logged: 0</p>
    <script>
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kinetic;
    document.getElementById('has').textContent = h ? 'handler: yes' : 'handler: no';
    let start = 0, end = 0, left = 0, paused = false;
    const post = (m) => h && h.postMessage(m);
    const startMsg = () => ({ type: 'timer.start', id: 'rest:' + start, kind: 'rest', label: 'Rest', endsAt: end, startedAt: start, next: { label: 'set 2 of Plank' } });
    function go() { start = Date.now(); end = start + 90000; post({ type: 'workout.start', title: 'Bridge test' }); post(startMsg()); }
    function today(done) {
      const n = new Date(), later = new Date(n.getTime() + 2 * 3600e3), p = (x) => String(x).padStart(2, '0');
      post({ type: 'today', date: n.getFullYear() + '-' + p(n.getMonth() + 1) + '-' + p(n.getDate()), title: 'Legs A', kind: 'workout',
        done, minutes: 45, weekDone: done ? 3 : 2, weekPlanned: 4, streakWeeks: 3, trainingDays: [0, 1, 2, 3, 4, 5, 6],
        usualTime: p(later.getHours()) + ':' + p(later.getMinutes()) });
    }
    // Log set (#573): the open exercise's next set, as Training sends it, and the log command
    let setNo = 2, logged = 0;
    const nextSet = () => setNo > 4 ? null : { exercise: 'Chest press machine', set: setNo, of: 4, weight: 105, reps: 10,
      label: 'Chest press machine · set ' + setNo + ' of 4 · 105 × 10', rest: 90 };
    function openEx() { post({ type: 'workout.start', title: 'Bridge test' }); post({ type: 'set.next', next: nextSet() }); }
    function logIt(at) {
      if (!nextSet()) return;
      logged++; setNo++;
      document.getElementById('logged').textContent = 'logged: ' + logged;
      post({ type: 'set.logged', exercise: 'Chest press machine' });
      start = at; end = start + 90000; paused = false;
      post(Object.assign(startMsg(), { nextSet: nextSet() }));
      post({ type: 'set.next', next: nextSet() });
    }
    function fin() { post({ type: 'timer.cancel', id: 'rest:' + start }); post({ type: 'workout.finish', summary: { mins: 1, exercises: 1, sets: 1, steps: 0 } }); }
    addEventListener('kinetic:command', (e) => {
      const c = typeof e.detail === 'string' ? e.detail : e.detail && e.detail.command;
      document.getElementById('cmd').textContent = 'command: ' + c + (c === 'rest' ? ' ' + e.detail.seconds : '');
      if (c === 'log') { const at = e.detail && e.detail.at; logIt(typeof at === 'number' && at <= Date.now() ? at : Date.now()); }
      if (c === 'rest') { paused = false; start = Date.now(); end = start + e.detail.seconds * 1000; post({ type: 'workout.start', title: 'Bridge test' }); post(startMsg()); }
      if (c === 'add15' && !paused) { end += 15000; post(startMsg()); }
      if (c === 'pause' && !paused) { paused = true; left = end - Date.now(); post({ type: 'timer.pause', id: 'rest:' + start, remaining: left }); }
      if (c === 'resume' && paused) { paused = false; end = Date.now() + left; post({ type: 'timer.resume', id: 'rest:' + start, endsAt: end }); }
    });
    </script></body></html>
    """
}
