import XCTest

/// Virt in the iPhone simulator: the studio's sign-in opens inside the app, the offline screen and Retry, and the
/// bridge end to end with a stand-in page (the real Training page is behind the sign-in, which a GitHub Mac can't
/// pass): a rest's alert, the screen kept on, the Live Activity, and a lock-screen button reaching the page.
final class VirtUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-uitest-reset"]
        app.launchEnvironment = env
        app.launch()
        return app
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

    /// Seconds to zero, as the status line says ("ends in 87s").
    func endsIn(_ app: XCUIApplication) -> Int? {
        let t = status(app)
        guard let r = t.range(of: #"ends in (-?\d+)s"#, options: .regularExpression) else { return nil }
        return Int(t[r].dropFirst("ends in ".count).dropLast())
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
        let before = endsIn(app) ?? 0
        app.buttons["dbg-add15"].tap()
        XCTAssertTrue(web.staticTexts["command: add15"].waitForExistence(timeout: 10), "the page got kinetic:command")
        let after = endsIn(app) ?? 0
        XCTAssertTrue(after >= before + 10 && after <= before + 15, "+15 moved the end: \(before)s, then \(status(app))")
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

    /// Talks to the app the way studio Training does (docs/kinetic/bridge.md on the website).
    static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#f4ede1"></head>
    <body style="font: 18px -apple-system; padding: 16px; background: #f4ede1; color: #2a1d12">
    <h2>Bridge check</h2>
    <p id="has">handler: no</p>
    <p><button onclick="go()" style="font-size: 20px">Start rest</button> <button onclick="fin()" style="font-size: 20px">Finish</button></p>
    <p id="cmd">command: none</p>
    <script>
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kinetic;
    document.getElementById('has').textContent = h ? 'handler: yes' : 'handler: no';
    let start = 0, end = 0, left = 0, paused = false;
    const post = (m) => h && h.postMessage(m);
    const startMsg = () => ({ type: 'timer.start', id: 'rest:' + start, kind: 'rest', label: 'Rest', endsAt: end, startedAt: start, next: { label: 'set 2 of Plank' } });
    function go() { start = Date.now(); end = start + 90000; post({ type: 'workout.start', title: 'Bridge test' }); post(startMsg()); }
    function fin() { post({ type: 'timer.cancel', id: 'rest:' + start }); post({ type: 'workout.finish', summary: { mins: 1, exercises: 1, sets: 1, steps: 0 } }); }
    addEventListener('kinetic:command', (e) => {
      const c = typeof e.detail === 'string' ? e.detail : e.detail && e.detail.command;
      document.getElementById('cmd').textContent = 'command: ' + c;
      if (c === 'add15' && !paused) { end += 15000; post(startMsg()); }
      if (c === 'pause' && !paused) { paused = true; left = end - Date.now(); post({ type: 'timer.pause', id: 'rest:' + start, remaining: left }); }
      if (c === 'resume' && paused) { paused = false; end = Date.now() + left; post({ type: 'timer.resume', id: 'rest:' + start, endsAt: end }); }
    });
    </script></body></html>
    """
}
