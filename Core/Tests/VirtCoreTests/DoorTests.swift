import XCTest
@testable import VirtCore

/// Training for friends (#578, part 2): the two doors, the friend's session, the sign-in's answers, and which pages a
/// friend's Virt opens.
final class DoorTests: XCTestCase {
    // MARK: - The door

    func testTylersPhoneKeepsGoingStraightToTheStudio() {
        XCTAssertEqual(Door.resolve(saved: nil, usedBefore: true), .tyler, "a phone that used Virt before doors: no question")
        XCTAssertNil(Door.resolve(saved: nil, usedBefore: false), "a new phone: the first screen asks")
        XCTAssertEqual(Door.resolve(saved: "friend", usedBefore: true), .friend, "a saved choice wins")
        XCTAssertEqual(Door.resolve(saved: "tyler", usedBefore: false), .tyler)
        XCTAssertNil(Door.resolve(saved: "none", usedBefore: true), "signed out of a door: asks again, even on Tyler's phone")
        XCTAssertNil(Door.resolve(saved: "something-newer", usedBefore: true), "an unknown value asks again")
        XCTAssertEqual(Door.tyler.home, Navigation.home)
        XCTAssertEqual(Door.friend.home.absoluteString, "https://train.time2play.live/")
        XCTAssertEqual(Door.key, "virt.door")
    }

    /// A phone still on the studio's sign-in is shown Sign in with Apple once (#732); after that its choice stands.
    func testTheStudioDoorIsOfferedAppleOnce() {
        XCTAssertNil(Door.atLaunch(saved: "tyler", usedBefore: true, appleAsked: false), "Tyler's phone from before Apple sign-in: the first screen, once")
        XCTAssertNil(Door.atLaunch(saved: nil, usedBefore: true, appleAsked: false), "and a phone that used Virt before doors")
        XCTAssertNil(Door.atLaunch(saved: "tyler", usedBefore: true, appleAsked: true), "the studio's sign-in is gone: the first screen, every time")
        XCTAssertEqual(Door.atLaunch(saved: "tyler", usedBefore: true, appleAsked: true, studioAllowed: true), .tyler, "only the test build still opens it")
        XCTAssertNil(Door.atLaunch(saved: "tyler", usedBefore: true, appleAsked: false, studioAllowed: true))
        XCTAssertEqual(Door.atLaunch(saved: "friend", usedBefore: true, appleAsked: false), .friend, "an Apple sign-in is never asked again")
        XCTAssertNil(Door.atLaunch(saved: "none", usedBefore: true, appleAsked: true), "signed out: the first screen, as before")
        XCTAssertNil(Door.atLaunch(saved: nil, usedBefore: false, appleAsked: false), "a new phone: the first screen")
    }

    // MARK: - The session

    func testSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = FriendSession(token: String(repeating: "a1", count: 32), name: "Sam", expires: 1_800_000_000_000 + 1000)
        XCTAssertTrue(s.usable(now: now))
        XCTAssertFalse(FriendSession(token: s.token, name: "Sam", expires: 1_800_000_000_000 - 1).usable(now: now), "run out")
        XCTAssertTrue(FriendSession(token: s.token, name: "Sam").usable(now: now), "no end given")
        XCTAssertFalse(FriendSession(token: "short", name: "Sam").usable(now: now))
        XCTAssertFalse(FriendSession.tokenOk("abcdefghijklmnop'; alert(1)//"), "letters and digits only")
        XCTAssertFalse(FriendSession.tokenOk("abcdefghijklmnopé"), "ASCII only")
        XCTAssertEqual(FriendSession.decode(s.encoded()!), s)
        // saved by an older build, with a field it didn't know yet: still reads
        let older = #"{"token":"\#(s.token)","name":"Sam"}"#
        XCTAssertEqual(FriendSession.decode(Data(older.utf8))?.name, "Sam")
        let newer = #"{"token":"\#(s.token)","name":"Sam","expires":5,"later":true}"#
        XCTAssertEqual(FriendSession.decode(Data(newer.utf8))?.expires, 5, "a field from a newer build is ignored")
    }

    // MARK: - The sign-in's talk with the website

    func testAppleBody() throws {
        let b = FriendSignIn.appleBody(identityToken: "a.b.c", name: "Sam", over13: true, app: "virt 1.0")
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: b) as? [String: Any])
        XCTAssertEqual(j["identityToken"] as? String, "a.b.c")
        XCTAssertEqual(j["name"] as? String, "Sam")
        XCTAssertEqual(j["over13"] as? Bool, true)
        XCTAssertEqual(j["app"] as? String, "virt 1.0")
        XCTAssertEqual(j["face"] as? Int, 9)
        XCTAssertEqual(FriendSignIn.url("apple").absoluteString, "https://tyleralocke.com/live/players/apple")
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: FriendSignIn.deleteBody(authorizationCode: "c1")) as? [String: Any])
        XCTAssertEqual(d["authorizationCode"] as? String, "c1")
        XCTAssertEqual(String(data: FriendSignIn.deleteBody(authorizationCode: nil), encoding: .utf8), "{}")
    }

    func testOutcomes() {
        let token = String(repeating: "f0", count: 32)
        let ok = #"{"ok":true,"account":{"id":"a_1","name":"Sam","face":9},"token":"\#(token)","expires":1800000000000}"#
        XCTAssertEqual(FriendSignIn.outcome(status: 200, body: Data(ok.utf8)),
                       .signedIn(FriendSession(token: token, name: "Sam", expires: 1_800_000_000_000)))
        let o = { (s: Int, b: String) in FriendSignIn.outcome(status: s, body: Data(b.utf8)) }
        XCTAssertEqual(o(400, #"{"ok":false,"error":"Pick a name of at least two characters.","code":"name"}"#), .needsName)
        XCTAssertEqual(o(403, #"{"ok":false,"error":"Accounts are for 13 and up.","code":"age"}"#), .tooYoung)
        XCTAssertEqual(o(401, #"{"ok":false,"error":"Sign in again.","code":"session"}"#), .signedOut)
        XCTAssertEqual(o(401, #"{"ok":false,"error":"Made for another app.","code":"apple"}"#), .failed("Made for another app."))
        XCTAssertEqual(o(404, "Not found"), .failed("Something went wrong (404). Try again."))
        XCTAssertEqual(o(0, ""), .failed("No connection. Check your signal and try again."))
        XCTAssertEqual(o(200, #"{"ok":true,"token":"bad token"}"#), .failed("Couldn't sign in. Try again."))
        XCTAssertEqual(FriendSignIn.stillSignedIn(status: 200, body: Data(#"{"ok":true,"account":{}}"#.utf8)), true)
        XCTAssertEqual(FriendSignIn.stillSignedIn(status: 401, body: Data()), false)
        XCTAssertNil(FriendSignIn.stillSignedIn(status: 0, body: Data()), "no signal never signs anyone out")
        XCTAssertNil(FriendSignIn.stillSignedIn(status: 503, body: Data()))
    }

    func testHandoverScript() throws {
        let token = String(repeating: "ab12", count: 8)
        let s = try XCTUnwrap(FriendSignIn.handoverScript(token: token))
        XCTAssertTrue(s.contains("window.T2P_SESSION = '\(token)'"), "the name the page's client.js reads")
        XCTAssertTrue(s.contains("location.hostname === 'train.time2play.live'"), "only on the friends' page")
        XCTAssertTrue(s.contains("location.protocol === 'https:'"))
        XCTAssertNil(FriendSignIn.handoverScript(token: "abcdefghijklmnop'+x+'"), "never writes anything but letters and digits")
        XCTAssertTrue(FriendSignIn.signOutWatchScript.contains("[data-sign-out]"), "the page's Sign out here button")
        XCTAssertTrue(FriendSignIn.signOutWatchScript.contains("virtAccount"))
        XCTAssertEqual(FriendSignIn.cleanName("  Sam  "), "Sam")
        XCTAssertNil(FriendSignIn.cleanName(" S "))
        XCTAssertEqual(FriendSignIn.cleanName(String(repeating: "x", count: 40))?.count, 24)
    }

    // MARK: - Pages

    func choose(_ s: String, door: Door, main: Bool = true) -> Navigation.Choice {
        Navigation.choose(URL(string: s), mainFrame: main, door: door)
    }

    func testAFriendSeesNoneOfTylersPages() {
        XCTAssertEqual(choose("https://train.time2play.live/", door: .friend), .load)
        XCTAssertEqual(choose("https://train.time2play.live/privacy", door: .friend), .load)
        XCTAssertEqual(choose("https://studio.tyleralocke.com/training", door: .friend), .openOutside, "the studio never opens inside")
        XCTAssertEqual(choose("https://tyleralocke.com/", door: .friend), .openOutside)
        XCTAssertEqual(choose("https://proud-unit-177a.cloudflareaccess.com/cdn-cgi/access/login/x", door: .friend), .openOutside)
        XCTAssertEqual(choose("https://time2play.live/", door: .friend), .openOutside)
        XCTAssertEqual(choose("https://train.time2play.live.example.com/", door: .friend), .openOutside, "a look-alike")
        XCTAssertEqual(choose("http://train.time2play.live/", door: .friend), .openOutside, "https only")
        XCTAssertEqual(choose("javascript:alert(1)", door: .friend), .block)
        XCTAssertEqual(choose("https://www.youtube.com/embed/x", door: .friend, main: false), .load, "frames load where they are")
        // Tyler's door is unchanged, and train.time2play.live isn't part of it
        XCTAssertEqual(choose("https://studio.tyleralocke.com/training", door: .tyler), .load)
        XCTAssertEqual(choose("https://train.time2play.live/", door: .tyler), .openOutside)
    }

    func testFriendTrainingAndToday() {
        let u = { (s: String) in URL(string: s) }
        XCTAssertTrue(Navigation.isTraining(u("https://train.time2play.live/#today"), door: .friend))
        XCTAssertFalse(Navigation.isTraining(u("https://train.time2play.live/privacy"), door: .friend))
        XCTAssertFalse(Navigation.isTraining(u("https://studio.tyleralocke.com/training"), door: .friend))
        XCTAssertFalse(Navigation.isSignIn(u("https://proud-unit-177a.cloudflareaccess.com/"), door: .friend))
        XCTAssertEqual(Navigation.todayAction(current: u("https://train.time2play.live/#history"), midWorkout: false, door: .friend), .stay)
        XCTAssertEqual(Navigation.todayAction(current: u("https://train.time2play.live/privacy"), midWorkout: false, door: .friend), .loadHome)
        XCTAssertEqual(Navigation.todayAction(current: u("https://train.time2play.live/privacy"), midWorkout: true, door: .friend), .stay)
    }

    /// Info.plist's WKAppBoundDomains (project.yml) and Navigation.appBoundDomains are the same list.
    func testBoundDomainsMatchProjectYml() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        var list: [String] = []
        var inside = false
        for line in yml.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("WKAppBoundDomains:") { inside = true; continue }
            guard inside else { continue }
            if t.hasPrefix("#") { continue }
            if t.hasPrefix("- ") { list.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)); continue }
            break
        }
        XCTAssertEqual(list, Navigation.appBoundDomains)
        XCTAssertTrue(list.contains("train.time2play.live"))
        XCTAssertLessThanOrEqual(list.count, 10, "iOS allows ten")
    }

    // MARK: - Tyler's own Training with Apple (#732)

    func testOwnerOutcomes() throws {
        let tok = "TLowner" + String(repeating: "a", count: 48)
        let ok = Data("{\"ok\":true,\"token\":\"\(tok)\",\"expires\":1800000000000}".utf8)
        guard case .owner(let s) = OwnerSignIn.outcome(status: 200, body: ok) else { return XCTFail("the owner's session") }
        XCTAssertTrue(s.isOwner)
        XCTAssertEqual(s.token, tok)
        XCTAssertEqual(s.expires, 1_800_000_000_000)
        let notLinked = Data("{\"ok\":false,\"code\":\"not-linked\",\"link\":\"AB12\"}".utf8)
        XCTAssertEqual(OwnerSignIn.outcome(status: 403, body: notLinked), .notLinked(code: "AB12"))
        // a bad code is never put into a script
        XCTAssertEqual(OwnerSignIn.outcome(status: 403, body: Data("{\"code\":\"not-linked\",\"link\":\"x';\"}".utf8)), .unavailable)
        // the switch off (a 404), no answer, a server problem: go on as a friend
        XCTAssertEqual(OwnerSignIn.outcome(status: 404, body: Data()), .unavailable)
        XCTAssertEqual(OwnerSignIn.outcome(status: 0, body: Data()), .unavailable)
        XCTAssertEqual(OwnerSignIn.outcome(status: 500, body: Data("{}".utf8)), .unavailable)
        XCTAssertEqual(OwnerSignIn.url("owner/apple").absoluteString, "https://train.time2play.live/live/train/owner/apple")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OwnerSignIn.appleBody(identityToken: "abc")) as? [String: String])
        XCTAssertEqual(body, ["identityToken": "abc"])
    }

    /// The owner flag is an added, optional field: a session saved by the previous version still reads, as a friend's.
    func testOwnerFieldReadsOldSessions() throws {
        let old = Data("{\"token\":\"uitestfriendsession0123456789\",\"name\":\"Sam\"}".utf8)
        let s = try XCTUnwrap(FriendSession.decode(old))
        XCTAssertFalse(s.isOwner)
        let back = try XCTUnwrap(FriendSession.decode(try XCTUnwrap(FriendSession(token: s.token, name: "Tyler", owner: true).encoded())))
        XCTAssertTrue(back.isOwner)
    }

    func testLinkScriptsStayOnTheStudio() {
        XCTAssertTrue(OwnerSignIn.linkScript.contains("location.hostname !== 'studio.tyleralocke.com'"))
        XCTAssertTrue(OwnerSignIn.linkScript.contains("/api/training-owner"))
        XCTAssertTrue(OwnerSignIn.waitingScript.contains("studio.gym.queue"))
        XCTAssertTrue(OwnerSignIn.codeOk("AB12"))
        XCTAssertFalse(OwnerSignIn.codeOk("ab12"))
        XCTAssertFalse(OwnerSignIn.codeOk("AB1"))
    }

    func testTylersPhoneNeverFallsIntoAFriendAccount() {
        XCTAssertEqual(Door.ownerStep(owner: true, notLinked: false, studioUsed: false, ownerOpened: false), .open)
        XCTAssertEqual(Door.ownerStep(owner: false, notLinked: true, studioUsed: true, ownerOpened: false), .link)
        XCTAssertEqual(Door.ownerStep(owner: false, notLinked: true, studioUsed: false, ownerOpened: true), .link)
        XCTAssertEqual(Door.ownerStep(owner: false, notLinked: false, studioUsed: true, ownerOpened: true), .sayUnreachable)
        XCTAssertEqual(Door.ownerStep(owner: false, notLinked: true, studioUsed: false, ownerOpened: false), .goOnAsFriend, "a friend")
        XCTAssertEqual(Door.ownerStep(owner: false, notLinked: false, studioUsed: false, ownerOpened: false), .goOnAsFriend)
        XCTAssertEqual(Door.ownerStep(owner: false, notLinked: false, studioUsed: true, ownerOpened: false), .goOnAsFriend,
                       "before he has linked, the owner path being off still lets the sign-in go on")
    }
}
