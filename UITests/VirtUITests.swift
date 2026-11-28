import XCTest

/// Virt in the iPhone simulator: the intro playing straight into Training with no lock (Nov 28: nothing asks for Face
/// ID or the passcode), the app switcher's cover, the studio's sign-in opens inside the app, the offline screen and Retry, and the bridge end to end with a stand-in page (the real Training page is behind the sign-in, which a GitHub Mac can't
/// pass): a rest's alert, the screen kept on, the Live Activity, and a lock-screen button reaching the page.
final class VirtUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Opens Virt and, unless `waitForIntro` is false, waits for the intro (the launch clip, then the unlock clip) to
    /// play into the app by itself: there's nothing to answer on the way, since Virt has no lock (Nov 28).
    /// `args` adds the test build's door: `-uitest-door-none` (the first screen) or `-uitest-door-friend`; Tyler's
    /// otherwise.
    func launch(env: [String: String] = [:], waitForIntro: Bool = true, args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset"] + args
        app.launchEnvironment = env
        app.launch()
        if waitForIntro {
            let intro = app.otherElements["intro"]
            _ = intro.waitForExistence(timeout: 5)
            XCTAssertTrue(intro.waitForNonExistence(timeout: 20), "the intro plays into the app by itself: \(introStage(app))")
        }
        return app
    }

    /// Where the intro is, as the test build's intro window says ("launch", "unlock" or "done").
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

    /// How many `kinetic:prefs` events Virt has sent the page, as the status line says ("prefs sent 3").
    func prefsSent(_ app: XCUIApplication) -> Int? {
        let t = status(app)
        guard let r = t.range(of: #"prefs sent \d+"#, options: .regularExpression) else { return nil }
        return Int(t[r].dropFirst("prefs sent ".count))
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

    // MARK: - Training's screens inside the app (tyleralocke#822)

    /// Bundled mode (`-uitest-bundle`: the test build makes a tiny bundle of its own, with this stand-in page as its
    /// front page): Training loads from virt-app://train/ with no network, its script comes from the bundle with the
    /// right type, a file that isn't in the manifest is a 404, the session is handed over, the page is told it's
    /// bundled and where its API is, the kinetic bridge works both ways, and the page's own "Sign out here" signs
    /// Virt out too.
    func testBundledTrainingLoadsFromInsideTheApp() {
        let token = "uitestfriendsession0123456789"
        let app = launch(env: ["VIRT_TEST_HTML": Self.bundledPage, "VIRT_FRIEND_TOKEN": token], args: ["-uitest-door-friend", "-uitest-bundle"])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), "the kinetic bridge on the bundled page: \(status(app))")
        XCTAssertTrue(waitStatus(app, contains: "page virt-app://train/"), status(app))
        XCTAssertTrue(status(app).contains("bundle fixture-1"), status(app))
        XCTAssertTrue(status(app).contains("door friend"), status(app))
        XCTAssertTrue(web.staticTexts["origin: virt-app://train"].exists, "the page's own address")
        XCTAssertTrue(web.staticTexts["session: handed over"].exists, "the session, before the page's scripts")
        XCTAssertTrue(web.staticTexts["app: bundled, build ok"].exists, "window.kineticApp says bundled and the build number")
        XCTAssertTrue(web.staticTexts["api: https://train.time2play.live"].exists, "window.T2P_API_BASE")
        XCTAssertTrue(web.staticTexts["script: loaded"].waitForExistence(timeout: 10), "a script file from the bundle ran")
        XCTAssertTrue(web.staticTexts["missing: 404"].waitForExistence(timeout: 10), "a path that isn't in the manifest is a 404")
        sleep(1)
        shot("bundled-today")

        web.buttons["Start rest"].tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), status(app))
        XCTAssertTrue(status(app).contains("alerts 1"), "the alert at zero: \(status(app))")
        XCTAssertTrue(status(app).contains("workout Full body A"), status(app))
        app.buttons["dbg-add15"].tap()
        XCTAssertTrue(web.staticTexts["command: add15"].waitForExistence(timeout: 10), "a lock-screen button reaches the bundled page")
        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer none"), status(app))

        // 9 seconds on, the bundle is still the one in use: its first message called the start watch off
        sleep(9)
        XCTAssertTrue(status(app).contains("bundle fixture-1"), status(app))
        XCTAssertFalse(status(app).contains("failed"), status(app))

        web.buttons["Sign out here"].tap()
        XCTAssertTrue(app.staticTexts["welcome-line"].waitForExistence(timeout: 10), "signed out from the bundled page: the first screen")
    }

    /// A guest in bundled mode: "Try a workout" opens virt-app://train/try with no session. A link to the site's
    /// Privacy page opens the bundle's own copy, and a link to anywhere else goes to Safari, never inside.
    func testBundledGuestPrivacyAndOutsideLinks() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.bundledPage], args: ["-uitest-door-none", "-uitest-bundle"])
        let tryIt = app.buttons["try-workout"]
        XCTAssertTrue(tryIt.waitForExistence(timeout: 15), "Try a workout, on the first screen")
        tryIt.tap()
        XCTAssertTrue(waitStatus(app, contains: "door friend guest", 15), status(app))
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), "the bridge works for a bundled guest: \(status(app))")
        XCTAssertTrue(status(app).contains("page virt-app://train/try"), status(app))
        XCTAssertTrue(web.staticTexts["session: none"].exists, "no session: a guest has no account")
        XCTAssertTrue(web.staticTexts["app: bundled, build ok"].exists)

        web.links["Privacy"].tap()
        XCTAssertTrue(web.staticTexts["privacy: from the bundle"].waitForExistence(timeout: 10), "the site's Privacy link opens the bundle's page: \(status(app))")
        XCTAssertTrue(waitStatus(app, contains: "page virt-app://train/privacy", 5), status(app))
        XCTAssertEqual(app.state, .runningForeground, "nothing was sent to Safari")
        sleep(1)
        shot("bundled-privacy")

        web.links["Outside"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30), "an outside link opens in Safari")
        app.activate()
        XCTAssertTrue(waitStatus(app, contains: "page virt-app://train/privacy", 15), "and never loaded inside: \(status(app))")
    }

    /// A bundle whose page never speaks on the bridge (a broken version): after 8 seconds Virt marks it failed and
    /// goes back; with nothing older here, that's the website, as before bundles.
    func testABundleThatDoesNotStartFallsBack() {
        let token = "uitestfriendsession0123456789"
        let app = launch(env: ["VIRT_TEST_HTML": Self.friendPage, "VIRT_FRIEND_TOKEN": token], args: ["-uitest-door-friend", "-uitest-bundle"])
        XCTAssertTrue(waitStatus(app, contains: "bundle none (failed fixture-1)", 30), "the silent bundle was given up on: \(status(app))")
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), status(app))
        XCTAssertTrue(waitStatus(app, contains: "page https://train.time2play.live/"), "the website, as before: \(status(app))")
        XCTAssertTrue(web.staticTexts["session: handed over"].exists, "and the session still reaches it")
        XCTAssertFalse(status(app).contains("offline screen"), status(app))
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

    /// The zero sound with the phone locked (Tyler, Nov 27): the sound keeper follows the timer. The test build's
    /// `-uitest-keeper-away` counts the app as away, so the status line can be read with it open: on with a zero
    /// scheduled while resting, nothing scheduled while paused or after a skip, off when the workout ends. No
    /// notification permission is asked when a workout starts (the timer has no notifications).
    func testSoundKeeperFollowsTheTimer() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page], args: ["-uitest-keeper-away"])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitStatus(app, contains: "sound keeper off"), "no workout, no keeper: \(status(app))")

        web.buttons["Start rest"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), status(app))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.buttons["Allow"].waitForExistence(timeout: 3), "no notification ask for a workout")
        XCTAssertTrue(waitStatus(app, contains: "sound keeper on", 10), "the keeper runs in a workout: \(status(app))")
        let end = endsAt(app) ?? 0
        // Chime: the green light's count-in starts 3 s before the zero (Nov 27)
        XCTAssertTrue(status(app).range(of: #"cue \d+"#, options: .regularExpression) != nil, "a zero scheduled: \(status(app))")
        if let r = status(app).range(of: #"cue \d+"#, options: .regularExpression), let cue = Int(status(app)[r].dropFirst(4)) {
            XCTAssertTrue(abs(cue - (end - 3)) <= 1, "the count-in starts 3 s before the zero: cue \(cue), ends \(end)")
        }
        shot("keeper-on")

        app.buttons["dbg-pause"].tap()
        XCTAssertTrue(waitStatus(app, contains: "paused"), status(app))
        XCTAssertTrue(waitStatus(app, contains: "cue none", 5), "nothing to play while paused: \(status(app))")
        XCTAssertTrue(status(app).contains("sound keeper on"), "still the workout: \(status(app))")

        app.buttons["dbg-resume"].tap()
        XCTAssertTrue(waitStatus(app, contains: "running"), status(app))
        XCTAssertTrue(status(app).range(of: #"cue \d+"#, options: .regularExpression) != nil, "the zero is back: \(status(app))")

        app.buttons["dbg-skip"].tap()
        XCTAssertTrue(waitStatus(app, contains: "cue none", 5), "skipped: nothing ahead: \(status(app))")

        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "sound keeper off"), "the workout's over: \(status(app))")
        XCTAssertTrue(status(app).contains("cue none"), status(app))
    }

    /// The real trip: Virt leaves the screen mid-rest and the keeper starts; back on the screen it's off again and
    /// the app plays its own sounds, as before.
    func testSoundKeeperStartsWhenVirtLeavesTheScreen() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20))
        web.buttons["Start rest"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), status(app))
        XCTAssertTrue(status(app).contains("sound keeper off"), "on the screen, the app chimes itself: \(status(app))")
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(waitStatus(app, contains: "sound keeper off", 10), status(app))
        XCTAssertTrue(status(app).contains("keeper-seen on>off"), "it ran while away: \(status(app))")
        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer none"), status(app))
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
        let app = launch(args: ["-uitest-widgets"])
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

    /// One press is one set (Tyler, Nov 24: Log set on the lock screen logged a whole exercise): three presses in the
    /// same moment reach the page as one `log`, with its own id, and the page logs one set.
    func testABurstOfLogSetPressesLogsOneSet() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), "the page sees the kinetic handler")
        web.buttons["Open exercise"].tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "next Chest press machine · set 2 of 4 · 105 × 10"), status(app))
        XCTAssertTrue(app.buttons["dbg-log3"].waitForExistence(timeout: 10))
        app.buttons["dbg-log3"].tap()
        XCTAssertTrue(web.staticTexts["logged: 1"].waitForExistence(timeout: 10), "the page logged a set")
        XCTAssertTrue(web.staticTexts["log id: yes"].exists, "the log carried its own id")
        sleep(2)
        XCTAssertFalse(web.staticTexts["logged: 2"].exists, "one set for the burst, not three")
        XCTAssertTrue(waitStatus(app, contains: "next Chest press machine · set 3 of 4 · 105 × 10"), status(app))
        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 10))
        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "next none"), status(app))
    }

    /// Tyler, Nov 25: Log set from the lock screen with no Face ID. The simulator can't lock and press a Live Activity
    /// button, so this checks what can be: every button's intent runs locked and never opens the app (read from the
    /// real types), what a press reads is kept readable with the phone locked, and a press made while the page is asleep
    /// (or before iOS has made a screen for Virt) is held and reaches the page once it's up, as one set.
    func testLockScreenButtonsNeverAskToUnlock() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), "the page sees the kinetic handler")
        XCTAssertTrue(waitStatus(app, contains: "intents ok", 5), "every button's intent: \(status(app))")
        XCTAssertTrue(status(app).contains("locked-read ok"), "readable with the phone locked: \(status(app))")
        web.buttons["Open exercise"].tap()
        allowAlerts()
        XCTAssertTrue(waitStatus(app, contains: "next Chest press machine · set 2 of 4 · 105 × 10"), status(app))
        XCTAssertTrue(status(app).contains("held 0"), status(app))
        XCTAssertTrue(app.buttons["dbg-logheld"].waitForExistence(timeout: 10))
        app.buttons["dbg-logheld"].tap()
        XCTAssertTrue(waitStatus(app, contains: "held 1", 3), "the press waits for the page: \(status(app))")
        XCTAssertTrue(status(app).contains("timer virt-rest:"), "its rest started with the page asleep: \(status(app))")
        XCTAssertFalse(web.staticTexts["logged: 1"].exists, "not handed to a sleeping page")
        XCTAssertTrue(web.staticTexts["logged: 1"].waitForExistence(timeout: 10), "handed over once the page was up: \(status(app))")
        XCTAssertTrue(web.staticTexts["log id: yes"].exists, "with its own id")
        XCTAssertTrue(waitStatus(app, contains: "held 0", 5), status(app))
        XCTAssertTrue(waitStatus(app, contains: "next Chest press machine · set 3 of 4 · 105 × 10"), "one set, not two: \(status(app))")
        sleep(2)
        XCTAssertFalse(web.staticTexts["logged: 2"].exists, "handed over once")
        XCTAssertTrue(status(app).contains("locked-read ok"), "still readable locked after the saves: \(status(app))")
        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 10))
        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "next none"), status(app))
    }

    /// The video intro's frames, held still (the test build's VIRT_INTRO_AT and VIRT_UNLOCK_AT, seconds into each
    /// clip): the word as the light crosses it, mid-wipe, the V growing, the launch clip's last frame, and the unlock
    /// clip flying into the V.
    func testIntroFrames() {
        let frames: [(String, [String: String])] = [
            ("intro-1-start", ["VIRT_INTRO_AT": "0.3"]),
            ("intro-2-word", ["VIRT_INTRO_AT": "1.5"]),
            ("intro-3-midwipe", ["VIRT_INTRO_AT": "2.3"]),
            ("intro-4-growing", ["VIRT_INTRO_AT": "2.95"]),
            ("intro-5-end", ["VIRT_INTRO_AT": "\(Self.launchLastFrame)"]),
            ("unlock-1-start", ["VIRT_UNLOCK_AT": "0"]),
            ("unlock-2-zoom", ["VIRT_UNLOCK_AT": "0.6"]),
            ("unlock-2b-edges", ["VIRT_UNLOCK_AT": "0.9"]),
            ("unlock-3-fly", ["VIRT_UNLOCK_AT": "1.2"]),
            ("unlock-4-past", ["VIRT_UNLOCK_AT": "1.45"]),
        ]
        for (name, env) in frames {
            let app = XCUIApplication()
            app.launchArguments = ["-uitest", "-uitest-reset"]
            app.launchEnvironment = env.merging(["VIRT_TEST_HTML": Self.page]) { a, _ in a }
            app.launch()
            XCTAssertTrue(app.otherElements["intro"].waitForExistence(timeout: 15), name)
            sleep(2)
            shot(name)
            app.terminate()
        }
    }

    /// No lock (Tyler, Nov 28: "the phone might need the Face ID to log in with Apple, but not to log into the app
    /// ever"): a fresh launch plays the launch clip, runs straight on into the unlock clip, and lands in Training by
    /// itself. Nothing asks for Face ID or the passcode on the way: no Unlock button, no system prompt.
    func testAFreshLaunchGoesStraightIntoTraining() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page], waitForIntro: false)
        let intro = app.otherElements["intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 10), "the intro first")
        usleep(1_000_000)
        shot("launch-1-clip")
        _ = waitIntro(app, "unlock", 8)  // for the picture; the order is checked on the status line below
        usleep(500_000)
        shot("launch-2-fly-in")
        XCTAssertTrue(intro.waitForNonExistence(timeout: 15), "the intro plays into Training by itself: \(introStage(app))")
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 10), "Training, with nothing to answer")
        XCTAssertTrue(studioShows(app))
        XCTAssertTrue(waitStatus(app, contains: "intro launch>unlock>done · ", 5), "launch clip, unlock clip, Training: \(status(app))")
        XCTAssertFalse(app.buttons["unlock"].exists, "no Unlock button anywhere")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists, "no system prompt")
        sleep(1)
        shot("launch-3-training")
    }

    /// A tap skips the launch clip: the unlock clip plays from its last frame, then Training.
    func testATapSkipsTheIntro() {
        // the launch clip at a fifth of its speed (about 20 s), so the tap lands during it on a slow simulator
        let app = launch(env: ["VIRT_TEST_HTML": Self.page, "VIRT_INTRO_RATE": "0.2"], waitForIntro: false)
        let skip = app.descendants(matching: .any)["skip-intro"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "the launch clip can be skipped")
        XCTAssertEqual(introStage(app), "launch")
        skip.tap()
        XCTAssertTrue(app.webViews["studio"].staticTexts["handler: yes"].waitForExistence(timeout: 8),
                      "the unlock clip, then Training, long before the slowed launch clip would have ended")
        XCTAssertTrue(waitStatus(app, contains: "intro launch>unlock>done · ", 5), "skipped to the unlock clip: \(status(app))")
    }

    /// Reduce Motion: no video at all, straight into Training.
    func testReduceMotionHasNoVideo() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page], waitForIntro: false, args: ["-uitest-reduce-motion"])
        XCTAssertTrue(app.webViews["studio"].staticTexts["handler: yes"].waitForExistence(timeout: 10))
        XCTAssertTrue(studioShows(app))
        XCTAssertTrue(waitStatus(app, contains: "intro done · ", 5), "no clip: \(status(app))")
        XCTAssertFalse(app.otherElements["intro"].exists)
    }

    /// The launch clip's last frame (seconds in): VIRT_INTRO_AT for the end of the clip. App/Intro/virt-launch.mp4.
    static let launchLastFrame = 3.99

    // MARK: - The app switcher's cover (no lock)

    /// The app switcher's picture shows the cover, not Training; coming back lifts it, with nothing to answer.
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
        XCTAssertFalse(app.otherElements["privacy-cover"].exists, "the cover lifted")
        XCTAssertFalse(app.otherElements["intro"].exists, "no intro on the way back")
        XCTAssertTrue(studioShows(app))
    }

    /// A phone that had build 100's Lock after set to Right away (that stored value stays on the phone, unread, for a
    /// rollback; `-lock.after now` puts it there): coming back, mid-workout or not, is straight into Training, the same
    /// page, with no intro and nothing to answer.
    func testComingBackNeverAsksEvenWithBuild100sLockSetting() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.page], args: ["-lock.after", "now"])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20))
        web.buttons["Start rest"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer rest:"), status(app))

        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 10), "mid-workout: straight back in")
        XCTAssertFalse(app.otherElements["intro"].exists, "no intro on the way back")

        web.buttons["Finish"].tap()
        XCTAssertTrue(waitStatus(app, contains: "timer none"), status(app))
        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        XCTAssertTrue(web.buttons["Finish"].waitForExistence(timeout: 10), "no workout: straight back in too, the same page")
        XCTAssertTrue(studioShows(app))
        XCTAssertFalse(app.otherElements["intro"].exists)
        XCTAssertFalse(app.otherElements["privacy-cover"].exists, "the cover lifted")
        XCTAssertFalse(app.buttons["unlock"].exists, "no Unlock button")
        XCTAssertTrue(status(app).contains("intro launch>unlock>done · "), "the intro played once, at launch: \(status(app))")
        shot("back-no-lock")
    }

    // MARK: - Settings through the bridge (the You tab)

    /// The page's You tab and Virt's settings sheet are two views of the same values: the page reads
    /// `kineticApp.prefs` at load (with no `lockAfter`: Virt has no lock since Nov 28), changes one with
    /// `{ type: 'pref' }`, and hears `kinetic:prefs` back; an older page's Lock after and a bad value are ignored; the
    /// next load starts with the new value; the sheet shows it; and the page's sign out asks with the sheet's own
    /// confirmation (cancelled here), while Delete account isn't offered on this door at all.
    func testThePageChangesASettingAndHearsIt() {
        let app = launch(env: ["VIRT_TEST_HTML": Self.prefsPage])
        let web = app.webViews["studio"]
        XCTAssertTrue(web.staticTexts["handler: yes"].waitForExistence(timeout: 20), status(app))
        XCTAssertTrue(web.staticTexts["at start: no lock, sounds true, style chime"].exists, "kineticApp.prefs before the page's scripts, no lockAfter")
        XCTAssertTrue(waitStatus(app, contains: "prefs sent"), status(app))
        sleep(2)
        let sentBefore = prefsSent(app)
        shot("prefs-start")

        // an older page's Lock after: ignored quietly (nothing stored, no kinetic:prefs, and still no lockAfter)
        web.buttons["Lock never"].tap()
        sleep(2)
        XCTAssertEqual(prefsSent(app), sentBefore, "no kinetic:prefs for it: \(status(app))")
        XCTAssertFalse(web.staticTexts["now: lock never"].exists, status(app))

        // the style list comes with the prefs (Nov 27: back to three, one plain list), and any id in it can be chosen
        XCTAssertTrue(web.staticTexts["styles: 3, first Chime (), last Classic ()"].exists, "kineticApp.prefs.soundStyles")
        web.buttons["Classic"].tap()
        XCTAssertTrue(waitStatus(app, contains: "style classic"), status(app))
        web.buttons["Glass"].tap()  // a style Virt no longer has: ignored
        sleep(2)
        XCTAssertTrue(status(app).contains("style classic"), status(app))

        // the sheet's list: the chosen one is checked; tapping another chooses it
        app.buttons["dbg-settings"].tap()
        let classic = app.buttons["style-classic"]
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 8))
        for _ in 0..<4 where !classic.isHittable { app.swipeUp() }
        XCTAssertTrue(classic.isSelected, "the page's choice is checked in the sheet")
        shot("sound-styles")
        app.buttons["style-digital"].tap()
        XCTAssertTrue(app.buttons["style-digital"].isSelected)
        XCTAssertFalse(classic.isSelected)
        app.buttons["settings-done"].tap()
        XCTAssertTrue(classic.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitStatus(app, contains: "style digital"), status(app))

        web.buttons["Sounds off"].tap()
        XCTAssertTrue(web.staticTexts["event: no lock, sounds false"].waitForExistence(timeout: 10), "kinetic:prefs reached the page")
        XCTAssertTrue(web.staticTexts["now: no lock, sounds false"].exists, "kineticApp.prefs is up to date too")

        app.buttons["dbg-reload"].tap()  // the test build loads the stand-in page again
        XCTAssertTrue(web.staticTexts["at start: no lock, sounds false, style digital"].waitForExistence(timeout: 20),
                      "the next load starts with the new values")

        // the native sheet shows the same values
        app.buttons["dbg-settings"].tap()
        let sounds = app.switches["sounds-toggle"]
        XCTAssertTrue(sounds.waitForExistence(timeout: 8), "Virt's settings sheet")
        XCTAssertEqual(sounds.value as? String, "0", "Sounds is off in the sheet too")
        shot("prefs-sheet")
        app.buttons["settings-done"].tap()
        XCTAssertTrue(sounds.waitForNonExistence(timeout: 5))

        // sign out from the page: the sheet's own confirmation asks (cancelled); Delete account: not on this door
        web.buttons["Delete account"].tap()
        sleep(2)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the studio's door has no Delete account: ignored")
        web.buttons["Sign out"].tap()
        let ask = app.alerts["Switch sign-in?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 8), "the page's sign out asks first")
        shot("prefs-sign-out")
        ask.buttons["Cancel"].tap()
        XCTAssertTrue(ask.waitForNonExistence(timeout: 5))
        XCTAssertTrue(web.staticTexts["handler: yes"].exists, "cancelled: still signed in, same page")
    }

    /// Stands in for the You tab: reads kineticApp.prefs at load, posts prefs (and, as an older page would, Lock after)
    /// and account asks, and shows each kinetic:prefs event.
    static let prefsPage = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#15171b"></head>
    <body style="font: 17px -apple-system; margin: 0; padding: 20px 18px; background: #15171b; color: #f2f2f2">
    <h2 style="margin: 0 0 10px">You</h2>
    <p id="has">handler: no</p>
    <p id="start">at start: none</p>
    <p id="event">event: none</p>
    <p id="now">now: none</p>
    <p><button onclick="pref('lockAfter', 'never')" style="font-size: 17px">Lock never</button>
    <button onclick="pref('sounds', false)" style="font-size: 17px">Sounds off</button></p>
    <p id="styles">styles: none</p>
    <p><button onclick="pref('soundStyle', 'classic')" style="font-size: 17px">Classic</button>
    <button onclick="pref('soundStyle', 'glass')" style="font-size: 17px">Glass</button></p>
    <p><button onclick="post({ type: 'signOut' })" style="font-size: 17px">Sign out</button>
    <button onclick="post({ type: 'deleteAccount' })" style="font-size: 17px">Delete account</button></p>
    <script>
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kinetic;
    document.getElementById('has').textContent = h ? 'handler: yes' : 'handler: no';
    const post = (m) => h && h.postMessage(m);
    const pref = (key, value) => post({ type: 'pref', key, value });
    const k = window.kineticApp || {};
    const p = k.prefs;
    const lock = (o) => o && 'lockAfter' in o ? 'lock ' + o.lockAfter : 'no lock';
    document.getElementById('start').textContent = p ? 'at start: ' + lock(p) + ', sounds ' + p.sounds + ', style ' + p.soundStyle : 'at start: none';
    const ls = (p && p.soundStyles) || [];
    if (ls.length) document.getElementById('styles').textContent = 'styles: ' + ls.length + ', first ' + ls[0].name + ' (' + ls[0].group + '), last ' + ls[ls.length - 1].name + ' (' + ls[ls.length - 1].group + ')';
    addEventListener('kinetic:prefs', (e) => {
      const d = e.detail || {};
      const now = window.kineticApp && window.kineticApp.prefs;
      document.getElementById('event').textContent = 'event: ' + lock(d) + ', sounds ' + d.sounds;
      document.getElementById('now').textContent = now ? 'now: ' + lock(now) + ', sounds ' + now.sounds : 'now: none';
    });
    </script></body></html>
    """

    /// Stands in for train.time2play.live's Today (the friends' Training): its paper look, the session the app hands
    /// over (window.T2P_SESSION, read once and deleted, as the page's client.js does), the kinetic bridge, and the
    /// page's own "Sign out here" (data-sign-out).
    /// The stand-in for Training's page inside the bundle (`-uitest-bundle` serves it at virt-app://train/ and
    /// /try). It says what it was given, loads a script from the bundle, asks for a file that isn't there, and
    /// posts a first bridge message as it opens, as Training does.
    static let bundledPage = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#15171b"></head>
    <body style="font: 17px -apple-system; margin: 0; padding: 20px 18px; background: #15171b; color: #f2f2f2">
    <h1 style="font: 700 30px -apple-system; margin: 6px 0 12px">Full body A</h1>
    <p><button onclick="go()" style="font-size: 18px; padding: 10px 18px; border: 0; border-radius: 12px; background: #ff4b3a; color: #fff">Start rest</button>
    <button onclick="fin()" style="font-size: 18px; padding: 10px 18px">Finish</button></p>
    <p><button data-sign-out onclick="out()" style="font-size: 16px">Sign out here</button></p>
    <p><a href="https://train.time2play.live/privacy" style="color: #dfc297; font-size: 18px">Privacy</a></p>
    <p id="origin" style="font-size: 13px">origin: ?</p>
    <p id="session" style="font-size: 13px">session: none</p>
    <p id="has" style="font-size: 13px">handler: no</p>
    <p id="app" style="font-size: 13px">app: ?</p>
    <p id="api" style="font-size: 13px">api: none</p>
    <p id="script" style="font-size: 13px">script: no</p>
    <p id="missing" style="font-size: 13px">missing: ?</p>
    <p id="cmd" style="font-size: 13px">command: none</p>
    <script>
    const t = window.T2P_SESSION;
    try { delete window.T2P_SESSION; } catch (e) {}
    document.getElementById('origin').textContent = 'origin: ' + location.origin;
    document.getElementById('session').textContent = typeof t === 'string' && /^[A-Za-z0-9]{16,200}$/.test(t) ? 'session: handed over' : 'session: none';
    const k = window.kineticApp || {};
    document.getElementById('app').textContent = 'app: ' + (k.bundled === true ? 'bundled' : 'not bundled') + ', build ' + (typeof k.build === 'number' && k.build >= 0 ? 'ok' : 'missing');
    document.getElementById('api').textContent = 'api: ' + (window.T2P_API_BASE || 'none');
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kinetic;
    document.getElementById('has').textContent = h ? 'handler: yes' : 'handler: no';
    const post = (m) => h && h.postMessage(m);
    post({ type: 'set.next', next: null });
    let start = 0, end = 0;
    const startMsg = () => ({ type: 'timer.start', id: 'rest:' + start, kind: 'rest', label: 'Rest', endsAt: end, startedAt: start });
    function go() { start = Date.now(); end = start + 90000; post({ type: 'workout.start', title: 'Full body A' }); post(startMsg()); }
    function fin() { post({ type: 'timer.cancel', id: 'rest:' + start }); post({ type: 'workout.finish', summary: { mins: 1, exercises: 1, sets: 1, steps: 0 } }); }
    function out() { document.getElementById('session').textContent = 'signed out'; }
    addEventListener('kinetic:command', (e) => {
      const c = typeof e.detail === 'string' ? e.detail : e.detail && e.detail.command;
      document.getElementById('cmd').textContent = 'command: ' + c;
      if (c === 'add15') { end += 15000; post(startMsg()); }
    });
    fetch('/_train/immutable/not-in-the-manifest.js').then((r) => { document.getElementById('missing').textContent = 'missing: ' + r.status; },
      () => { document.getElementById('missing').textContent = 'missing: failed'; });
    </script>
    <script src="/_train/immutable/app.js"></script>
    </body></html>
    """

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
    <p id="logid">log id: none</p>
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
      if (c === 'log') {
        document.getElementById('logid').textContent = 'log id: ' + (typeof e.detail.id === 'string' && e.detail.id.length > 8 ? 'yes' : 'no');
        const at = e.detail && e.detail.at; logIt(typeof at === 'number' && at <= Date.now() ? at : Date.now());
      }
      if (c === 'rest') { paused = false; start = Date.now(); end = start + e.detail.seconds * 1000; post({ type: 'workout.start', title: 'Bridge test' }); post(startMsg()); }
      if (c === 'add15' && !paused) { end += 15000; post(startMsg()); }
      if (c === 'pause' && !paused) { paused = true; left = end - Date.now(); post({ type: 'timer.pause', id: 'rest:' + start, remaining: left }); }
      if (c === 'resume' && paused) { paused = false; end = Date.now() + left; post({ type: 'timer.resume', id: 'rest:' + start, endsAt: end }); }
    });
    </script></body></html>
    """
}
