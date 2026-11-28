import XCTest
@testable import VirtCore

/// Tyler, Nov 25: "I want to be able to lock my screen but not have to scan my face on my phone to log the set from the
/// lock screen." Every reason iOS could ask for an unlock is in docs/lock-screen-buttons.md; these check the ones
/// that can be checked off a real iPhone.
final class LockScreenButtonsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_107_600)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }

    // MARK: - What a locked phone can read

    func testKeychainClasses() {
        XCTAssertEqual(LockedAccess.keychainClass, "cku", "after first unlock, this phone only")
        XCTAssertTrue(LockedAccess.keychainReadableWhileLocked.contains(LockedAccess.keychainClass))
        for locked in ["ak", "aku", "akpu"] {
            XCTAssertTrue(LockedAccess.keychainNeedsMove(locked), "\(locked) can't be read with the phone locked")
        }
        for fine in ["ck", "cku", "dk", "dku"] { XCTAssertFalse(LockedAccess.keychainNeedsMove(fine), fine) }
        XCTAssertFalse(LockedAccess.keychainNeedsMove(nil), "no item: nothing to move")
        XCTAssertFalse(LockedAccess.keychainNeedsMove(""))
    }

    func testFileClasses() {
        XCTAssertTrue(LockedAccess.fileReadable(nil), "no class (the simulator) reads any time")
        XCTAssertTrue(LockedAccess.fileReadable("NSFileProtectionCompleteUntilFirstUserAuthentication"), "iOS's default")
        XCTAssertTrue(LockedAccess.fileReadable("NSFileProtectionNone"))
        XCTAssertFalse(LockedAccess.fileReadable("NSFileProtectionComplete"))
        XCTAssertFalse(LockedAccess.fileReadable("NSFileProtectionCompleteUnlessOpen"))
    }

    func testSummaryNamesWhatCantBeRead() {
        XCTAssertEqual(LockedAccess.summary(keychain: [("today", "cku"), ("friend", nil)], files: [("defaults", nil)]), "ok")
        XCTAssertEqual(LockedAccess.summary(keychain: [("today", "ak"), ("friend", "cku")],
                                            files: [("defaults", "NSFileProtectionComplete")]),
                       "today=ak,defaults=NSFileProtectionComplete")
    }

    // MARK: - Presses the page hasn't heard yet

    func testAHeldPressReachesThePageOnce() {
        var p = PendingLogs()
        p.add(at: s(10), id: "a")
        p.add(at: s(10), id: "a")
        p.add(at: s(5), id: "b")
        XCTAssertEqual(p.count, 2, "the same press is held once")
        XCTAssertEqual(p.take(now: s(60)), [.log(at: s(5), id: "b"), .log(at: s(10), id: "a")], "oldest first, with their ids")
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.take(now: s(61)), [], "handed over once")
    }

    func testOnlyLogsAreHeld() {
        var p = PendingLogs()
        p.hold(.timer(.add15))
        p.hold(.startToday)
        p.hold(.rest(seconds: 90))
        XCTAssertTrue(p.isEmpty, "a late +15 or skip would land on the wrong timer")
        p.hold(.log(at: s(1), id: "x"))
        p.hold(.log(at: s(2)))
        XCTAssertEqual(p.count, 2)
        if case .log(_, let id)? = p.take(now: s(3)).last { XCTAssertNotNil(id, "an old-shape log gets an id") } else { XCTFail() }
    }

    func testOldPressesAreDropped() {
        var p = PendingLogs()
        p.add(at: s(0), id: "old")
        p.add(at: s(PendingLogs.keepFor), id: "new")
        XCTAssertEqual(p.take(now: s(PendingLogs.keepFor + 1)), [.log(at: s(PendingLogs.keepFor), id: "new")])
    }

    func testHeldPressesSurviveTheAppBeingEnded() {
        var p = PendingLogs()
        p.add(at: s(1), id: "a")
        var back = PendingLogs.decode(p.encoded())
        XCTAssertEqual(back, p)
        XCTAssertEqual(back?.take(now: s(2)), [.log(at: s(1), id: "a")])
        XCTAssertNil(PendingLogs.decode(Data("nope".utf8)))
        XCTAssertNil(PendingLogs.decode(nil))
    }

    func testTheHeldListStaysSmall() {
        var p = PendingLogs()
        for i in 0..<(PendingLogs.limit + 5) { p.add(at: s(TimeInterval(i)), id: "p\(i)") }
        XCTAssertEqual(p.count, PendingLogs.limit)
        XCTAssertEqual(p.take(now: s(100)).first, .log(at: s(5), id: "p5"), "the oldest went first")
    }

    /// A press while the page is asleep moves the board on and is held; the page hears it when it's up, and the
    /// board's next set is still one on (never two).
    func testAPressWithNoPageIsHeldAndTheBoardMovesOnce() {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Upper A"), now: s(0))
        b.apply(.setNext(NextSet(exercise: "Row", set: 1, of: 3, weight: 90, reps: 10, label: "Row · set 1 of 3 · 90 × 10", rest: 60)),
                now: s(1))
        var gate = LogPress()
        var held = PendingLogs()
        if let c = gate.press(board: &b, now: s(10), id: "a") { held.hold(c) }
        XCTAssertEqual(b.nextSet?.set, 2)
        XCTAssertEqual(b.countdown?.endsAt, s(70), "the rest started with no page")
        XCTAssertEqual(held.take(now: s(30)), [.log(at: s(10), id: "a")])
    }

    // MARK: - Every button's intent (read from the source, so this runs on Linux too)

    /// The repo's root (Core/Tests/VirtCoreTests/this file).
    var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func sources(_ folders: [String]) -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for f in folders {
            let dir = root.appendingPathComponent(f)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names.sorted() where n.hasSuffix(".swift") {
                if let t = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) { out.append(("\(f)/\(n)", t)) }
            }
        }
        return out
    }

    func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// The struct's declaration line and body, up to its closing brace at the start of a line.
    func declaration(of type: String, in files: [(name: String, text: String)]) -> (conformances: String, body: String)? {
        for f in files {
            guard let r = f.text.range(of: "struct \(type):") else { continue }
            let rest = f.text[r.upperBound...]
            guard let brace = rest.firstIndex(of: "{") else { continue }
            let conformances = String(rest[..<brace])
            let end = rest.range(of: "\n}")?.lowerBound ?? rest.endIndex
            return (conformances, String(rest[brace..<end]))
        }
        return nil
    }

    func testEveryLockScreenButtonRunsLockedWithoutOpeningTheApp() throws {
        let files = sources(["Shared", "Widget", "App"])
        try XCTSkipIf(files.isEmpty, "the app's sources aren't next to the package")
        var intents = Set<String>()
        for f in files {
            intents.formUnion(matches(#"Button\(intent:\s*([A-Za-z_][A-Za-z0-9_]*)\("#, in: f.text))
            intents.formUnion(matches(#"ControlWidgetButton\(action:\s*([A-Za-z_][A-Za-z0-9_]*)\("#, in: f.text))
            intents.formUnion(matches(#"ControlWidgetToggle\([^)]*action:\s*([A-Za-z_][A-Za-z0-9_]*)\("#, in: f.text))
            intents.formUnion(matches(#"Toggle\(isOn:[^)]*intent:\s*([A-Za-z_][A-Za-z0-9_]*)\("#, in: f.text))
        }
        XCTAssertTrue(intents.contains("TimerCommandIntent"), "found the buttons: \(intents)")
        for name in intents.sorted() {
            guard let d = declaration(of: name, in: files) else { XCTFail("\(name) isn't declared in Shared, Widget or App"); continue }
            // runs in Virt's process, and is the kind of intent music apps' lock-screen buttons use
            XCTAssertTrue(d.conformances.contains("LiveActivityIntent"), "\(name): \(d.conformances)")
            XCTAssertTrue(d.conformances.contains("AudioPlaybackIntent"), "\(name): \(d.conformances)")
            XCTAssertFalse(d.conformances.contains("ForegroundContinuableIntent"), name)
            XCTAssertFalse(d.conformances.contains("OpenIntent"), name)
            // said outright, not left to the defaults
            XCTAssertTrue(d.body.contains("authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed"), name)
            XCTAssertTrue(d.body.contains("openAppWhenRun: Bool = false"), name)
            XCTAssertTrue(d.body.contains("supportedModes: IntentModes { .background }"), name)
            // nothing that stops to ask the person, or reaches for the app's screen
            for asks in ["requestConfirmation", "requestValue", "requestDisambiguation", "@Dependency", "continueInForeground",
                         "requiresAuthentication", "requiresLocalDeviceAuthentication"] {
                XCTAssertFalse(d.body.contains(asks), "\(name) uses \(asks)")
            }
        }
    }

    /// What a press runs in the app (Engine.command) asks iOS for nothing and never brings the app forward.
    func testWhatAPressRunsAsksForNothing() throws {
        let files = sources(["App"])
        try XCTSkipIf(files.isEmpty, "the app's sources aren't next to the package")
        guard let engine = files.first(where: { $0.name == "App/Engine.swift" })?.text,
              let start = engine.range(of: "func command(_ c: TimerCommand)") else { return XCTFail("Engine.command") }
        let rest = engine[start.upperBound...]
        let body = String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        for asks in ["requestAuthorization", "evaluatePolicy", "LAContext", "open(", "requestSceneSessionActivation",
                     "activateSceneSession", "AppCover"] {
            XCTAssertFalse(body.contains(asks), "a press runs \(asks)")
        }
    }

    /// No link in the Live Activity: a link opens the app, and opening an app from the Lock Screen asks to unlock.
    func testTheLiveActivityHasNoLinks() throws {
        let files = sources(["Shared", "Widget"]).filter { $0.name.hasSuffix("TimerViews.swift") || $0.name.hasSuffix("TimerLiveActivity.swift") }
        try XCTSkipIf(files.isEmpty, "the app's sources aren't next to the package")
        for f in files {
            XCTAssertFalse(f.text.contains("Link("), f.name)
            XCTAssertFalse(f.text.contains("widgetURL("), f.name)
        }
    }
}
