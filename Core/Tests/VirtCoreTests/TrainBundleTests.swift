import XCTest
@testable import VirtCore

/// Training's screens inside the app (tyleralocke#822): the manifest, which paths are safe, what each request gets,
/// when to update, which version to fall back to and when to check.
final class TrainBundleTests: XCTestCase {
    let a = String(repeating: "a", count: 64)
    let b = String(repeating: "b", count: 64)
    let c = String(repeating: "c", count: 64)

    func json(version: String = "build-1", minApp: Int = 80, extra: String = "", files: String? = nil, entries: String? = nil) -> Data {
        let f = files ?? """
            { "path": "/pages/index.html", "sha256": "\(a)", "bytes": 10 },
            { "path": "/pages/try.html", "sha256": "\(b)", "bytes": 11 },
            { "path": "/_train/immutable/entry/start.abc.js", "sha256": "\(c)", "bytes": 12, "later": true }
            """
        let e = entries ?? #"{ "/": "/pages/index.html", "/try": "/pages/try.html" }"#
        return Data("""
            { "v": 1, "version": "\(version)", "minApp": \(minApp), "latestApp": 81, "store": "", "someday": [1, 2],
              \(extra) "entries": \(e), "files": [ \(f) ] }
            """.utf8)
    }

    func manifest(_ version: String = "build-1", minApp: Int = 80, files: String? = nil) throws -> BundleManifest {
        try XCTUnwrap(BundleManifest.parse(json(version: version, minApp: minApp, files: files)))
    }

    // MARK: - The manifest

    func testReadsAManifestAndIgnoresWhatItDoesNotKnow() throws {
        let m = try manifest()
        XCTAssertEqual(m.version, "build-1")
        XCTAssertEqual(m.minApp, 80)
        XCTAssertEqual(m.latestApp, 81)
        XCTAssertEqual(m.store, "")
        XCTAssertEqual(m.base, "")
        XCTAssertEqual(m.files.count, 3)
        XCTAssertEqual(m.entries["/try"], "/pages/try.html")
        XCTAssertEqual(m.file("/pages/index.html"), BundleFile(path: "/pages/index.html", sha256: a, bytes: 10))
        XCTAssertEqual(BundleManifest.url.absoluteString, "https://train.time2play.live/app/manifest.json")
    }

    func testABadManifestIsNoManifest() {
        XCTAssertNil(BundleManifest.parse(Data("not json".utf8)))
        XCTAssertNil(BundleManifest.parse(Data("[]".utf8)))
        XCTAssertNil(BundleManifest.parse(Data("<html>Not found</html>".utf8)))
        XCTAssertNil(BundleManifest.parse(Data(String(decoding: json(), as: UTF8.self).replacingOccurrences(of: #""v": 1"#, with: #""v": 2"#).utf8)),
                     "a format this build doesn't know")
        XCTAssertNil(BundleManifest.parse(json(version: "../x")), "a version is a folder name")
        XCTAssertNil(BundleManifest.parse(json(version: ".hidden")))
        XCTAssertNil(BundleManifest.parse(json(version: "")))
        XCTAssertNil(BundleManifest.parse(json(files: "")), "no files")
        XCTAssertNil(BundleManifest.parse(json(files: #"{ "path": "/pages/index.html", "sha256": "abc", "bytes": 1 }"#)), "not a hash")
        XCTAssertNil(BundleManifest.parse(json(files: #"{ "path": "/pages/index.html", "sha256": "\#(a)", "bytes": -1 }"#)))
        XCTAssertNil(BundleManifest.parse(json(files: #"{ "path": "/pages/index.html", "sha256": "\#(a)" }"#)), "no size")
        XCTAssertNil(BundleManifest.parse(json(files: #"{ "path": "/../index.html", "sha256": "\#(a)", "bytes": 1 }"#)), "an unsafe path spoils it all")
        XCTAssertNil(BundleManifest.parse(json(entries: #"{ "/": "/pages/missing.html" }"#)), "a page with no file")
        XCTAssertNil(BundleManifest.parse(json(entries: #"{ "/try": "/pages/try.html" }"#)), "no front page")
        XCTAssertNil(BundleManifest.parse(json(entries: "{}")))
        XCTAssertNil(BundleManifest.parse(json(files: """
            { "path": "/pages/index.html", "sha256": "\(a)", "bytes": 10 }, { "path": "/pages/try.html", "sha256": "\(b)", "bytes": 11 },
            { "path": "/pages/index.html", "sha256": "\(b)", "bytes": 10 }
            """)), "the same path twice, differently")
    }

    func testHashesAreReadInLowercaseAndARepeatIsOnce() throws {
        let m = try XCTUnwrap(BundleManifest.parse(json(files: """
            { "path": "/pages/index.html", "sha256": "\(a.uppercased())", "bytes": 10 }, { "path": "/pages/try.html", "sha256": "\(b)", "bytes": 11 },
            { "path": "/pages/index.html", "sha256": "\(a)", "bytes": 10 }
            """)))
        XCTAssertEqual(m.files.count, 2)
        XCTAssertEqual(m.files[0].sha256, a)
    }

    func testBaseIsOnlyEverOnTheSite() throws {
        let m = try manifest()
        XCTAssertEqual(m.source(of: m.files[2])?.absoluteString, "https://train.time2play.live/_train/immutable/entry/start.abc.js")
        let based = try XCTUnwrap(BundleManifest.parse(json(extra: #""base": "/app/files","#)))
        XCTAssertEqual(based.base, "/app/files")
        XCTAssertEqual(based.source(of: based.files[0])?.absoluteString, "https://train.time2play.live/app/files/pages/index.html")
        let full = try XCTUnwrap(BundleManifest.parse(json(extra: #""base": "https://train.time2play.live/app/files/","#)))
        XCTAssertEqual(full.base, "/app/files")
        XCTAssertEqual(try XCTUnwrap(BundleManifest.parse(json(extra: #""base": "","#))).base, "")
        XCTAssertEqual(try XCTUnwrap(BundleManifest.parse(json(extra: #""base": null,"#))).base, "")
        XCTAssertNil(BundleManifest.parse(json(extra: #""base": "https://example.com/files","#)), "never another host")
        XCTAssertNil(BundleManifest.parse(json(extra: #""base": "http://train.time2play.live/x","#)), "never plain http")
        XCTAssertNil(BundleManifest.parse(json(extra: #""base": "/a/../b","#)))
        XCTAssertNil(BundleManifest.parse(json(extra: #""base": 7,"#)))
        let spaced = try manifest(files: """
            { "path": "/pages/index.html", "sha256": "\(a)", "bytes": 10 }, { "path": "/pages/try.html", "sha256": "\(b)", "bytes": 11 },
            { "path": "/img/goblet squat.webp", "sha256": "\(c)", "bytes": 5 }
            """)
        XCTAssertEqual(spaced.source(of: spaced.files[2])?.absoluteString, "https://train.time2play.live/img/goblet%20squat.webp")
        XCTAssertTrue(BundleManifest.allowed(URL(string: "https://train.time2play.live/x")))
        XCTAssertFalse(BundleManifest.allowed(URL(string: "http://train.time2play.live/x")))
        XCTAssertFalse(BundleManifest.allowed(URL(string: "https://tyleralocke.com/x")))
        XCTAssertFalse(BundleManifest.allowed(URL(string: "https://train.time2play.live.example.com/x")))
        XCTAssertFalse(BundleManifest.allowed(nil))
    }

    // MARK: - Paths

    func testPathSafety() {
        for good in ["/pages/index.html", "/_train/immutable/chunks/a.B-c_1.js", "/favicon.ico", "/img/goblet squat.webp", "/a"] {
            XCTAssertTrue(BundlePath.safe(good), good)
        }
        for bad in ["", "/", "pages/index.html", "/a/../b", "/..", "/a/..", "/a..b", "https://example.com/a", "/https://example.com", "//example.com/a",
                    "/a?x=1", "/a#b", "/a\\b", "/a/", "/a\nb", "/a\u{0}b", "/" + String(repeating: "x", count: 600)] {
            XCTAssertFalse(BundlePath.safe(bad), bad)
        }
        XCTAssertTrue(BundlePath.safePage("/"))
        XCTAssertTrue(BundlePath.safePage("/try"))
        XCTAssertFalse(BundlePath.safePage("/try?x"))
        XCTAssertTrue(BundlePath.safeVersion("1763373600000-abc_DEF.2"))
        for bad in ["", ".", "..", ".partial-x", "a/b", "a b", String(repeating: "v", count: 65)] {
            XCTAssertFalse(BundlePath.safeVersion(bad), bad)
        }
    }

    func testContentTypes() {
        XCTAssertEqual(BundleContent.type(forPath: "/pages/index.html"), "text/html; charset=utf-8")
        XCTAssertEqual(BundleContent.type(forPath: "/_train/immutable/entry/start.abc.js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(BundleContent.type(forPath: "/_train/immutable/assets/0.X.css"), "text/css; charset=utf-8")
        XCTAssertEqual(BundleContent.type(forPath: "/_train/version.json"), "application/json; charset=utf-8")
        XCTAssertEqual(BundleContent.type(forPath: "/fonts/a.woff2"), "font/woff2")
        XCTAssertEqual(BundleContent.type(forPath: "/img/SQUAT.PNG"), "image/png")
        XCTAssertEqual(BundleContent.type(forPath: "/img/a.webp"), "image/webp")
        XCTAssertEqual(BundleContent.type(forPath: "/img/a.svg"), "image/svg+xml")
        XCTAssertEqual(BundleContent.type(forPath: "/img/a.jpeg"), "image/jpeg")
        XCTAssertEqual(BundleContent.type(forPath: "/manifest.webmanifest"), "application/manifest+json; charset=utf-8")
        XCTAssertEqual(BundleContent.type(forPath: "/a.unknown"), "application/octet-stream")
        XCTAssertEqual(BundleContent.type(forPath: "/noextension"), "application/octet-stream")
        XCTAssertEqual(BundleContent.type(forPath: "/.hidden"), "application/octet-stream")
    }

    // MARK: - What a request gets

    func testRequestsMapToFilesPagesOrNotFound() throws {
        let m = try manifest()
        let index = BundleAnswer.file(BundleFile(path: "/pages/index.html", sha256: a, bytes: 10), type: BundleContent.html)
        let tryPage = BundleAnswer.file(BundleFile(path: "/pages/try.html", sha256: b, bytes: 11), type: BundleContent.html)
        XCTAssertEqual(m.answer(path: "/"), index)
        XCTAssertEqual(m.answer(path: ""), index)
        XCTAssertEqual(m.answer(path: "/try"), tryPage)
        XCTAssertEqual(m.answer(path: "/try/"), tryPage)
        XCTAssertEqual(m.answer(path: "/_train/immutable/entry/start.abc.js"),
                       .file(BundleFile(path: "/_train/immutable/entry/start.abc.js", sha256: c, bytes: 12), type: "text/javascript; charset=utf-8"))
        XCTAssertEqual(m.answer(path: "/pages/try.html"), tryPage, "a page's own file")
        XCTAssertEqual(m.answer(path: "/_train/immutable/entry/gone.js"), .notFound, "a file that isn't in the manifest")
        XCTAssertEqual(m.answer(path: "/nope.png"), .notFound)
        XCTAssertEqual(m.answer(path: "/app/manifest.json"), .notFound)
        XCTAssertEqual(m.answer(path: "/history"), index, "the page's own router takes an address that isn't a file")
        XCTAssertEqual(m.answer(path: "/plan/week/2"), index)
        XCTAssertEqual(m.answer(path: "/privacy"), index, "this manifest has no privacy page")
        XCTAssertEqual(m.answer(path: "/../etc/passwd"), .notFound)
        XCTAssertEqual(m.answer(path: "/a/../b"), .notFound)
        XCTAssertTrue(m.isPage("/"))
        XCTAssertTrue(m.isPage("/try/"))
        XCTAssertFalse(m.isPage("/privacy"))
        XCTAssertFalse(m.isPage("/pages/index.html"))
    }

    // MARK: - Updating

    func testUpdateDecision() throws {
        let m = try manifest("build-2")
        let fresh = BundleState(build: 80)
        // nothing on the phone yet: everything
        XCTAssertEqual(BundleUpdate.decide(state: fresh, shipped: nil, usable: [], build: 80, manifest: m, have: []), .download(m.files))
        // only the files whose contents aren't here
        XCTAssertEqual(BundleUpdate.decide(state: fresh, shipped: "build-1", usable: ["build-1"], build: 80, manifest: m, have: [a, b]),
                       .download([m.files[2]]))
        // everything's here under another version: nothing to fetch, but it becomes the newest
        XCTAssertEqual(BundleUpdate.decide(state: fresh, shipped: "build-1", usable: ["build-1"], build: 80, manifest: m, have: [a, b, c]), .download([]))
        // the same as what's shipped or newest: nothing
        XCTAssertEqual(BundleUpdate.decide(state: fresh, shipped: "build-2", usable: ["build-2"], build: 80, manifest: m, have: [a, b, c]), .nothing)
        XCTAssertEqual(BundleUpdate.decide(state: BundleState(current: "build-2", build: 80), shipped: "build-1", usable: ["build-1", "build-2"],
                                           build: 80, manifest: m, have: [a, b, c]), .nothing)
        // its folder is gone or broken: fetch what's missing again
        XCTAssertEqual(BundleUpdate.decide(state: BundleState(current: "build-2", build: 80), shipped: "build-1", usable: ["build-1"],
                                           build: 80, manifest: m, have: [a]), .download([m.files[1], m.files[2]]))
        // the site went back to the shipped version while a newer one is on the phone: make it the newest again
        XCTAssertEqual(BundleUpdate.decide(state: BundleState(current: "build-3", build: 80), shipped: "build-2", usable: ["build-2", "build-3"],
                                           build: 80, manifest: m, have: [a, b, c]), .download([]))
        // a version that failed is never fetched or tried again
        XCTAssertEqual(BundleUpdate.decide(state: BundleState(failed: ["build-2"], build: 80), shipped: "build-1", usable: ["build-1"],
                                           build: 80, manifest: m, have: []), .nothing)
    }

    func testABundleForANewerAppIsLeftAlone() throws {
        let m = try manifest("build-2", minApp: 81)
        XCTAssertEqual(BundleUpdate.decide(state: BundleState(build: 80), shipped: "build-1", usable: ["build-1"], build: 80, manifest: m, have: []), .tooOld)
        XCTAssertEqual(BundleUpdate.decide(state: BundleState(build: 81), shipped: "build-1", usable: ["build-1"], build: 81, manifest: m, have: [a, b]),
                       .download([m.files[2]]))
    }

    func testTheSameContentsAreFetchedOnce() throws {
        let m = try manifest(files: """
            { "path": "/pages/index.html", "sha256": "\(a)", "bytes": 10 }, { "path": "/pages/try.html", "sha256": "\(a)", "bytes": 10 }
            """)
        XCTAssertEqual(BundleUpdate.decide(state: BundleState(), shipped: nil, usable: [], build: 80, manifest: m, have: []), .download([m.files[0]]))
    }

    // MARK: - Falling back

    func testLaunchOrderIsNewestThenPreviousThenShipped() {
        var s = BundleState(current: "v3", previous: "v2", build: 80)
        let all: Set<String> = ["v1", "v2", "v3"]
        XCTAssertEqual(s.launchOrder(shipped: "v1", usable: all), ["v3", "v2", "v1"])
        XCTAssertEqual(s.launchOrder(shipped: "v1", usable: ["v1", "v3"]), ["v3", "v1"], "a version with files missing is skipped")
        XCTAssertEqual(s.launchOrder(shipped: nil, usable: all), ["v3", "v2"])
        XCTAssertEqual(BundleState().launchOrder(shipped: "v1", usable: ["v1"]), ["v1"])
        XCTAssertEqual(BundleState().launchOrder(shipped: nil, usable: []), [], "no bundle: the website, as before")
        XCTAssertEqual(BundleState(current: "v1", previous: "v1").launchOrder(shipped: "v1", usable: ["v1"]), ["v1"], "each one once")

        s.fail("v3")
        XCTAssertEqual(s.launchOrder(shipped: "v1", usable: all), ["v2", "v1"], "a failed version is never tried again")
        XCTAssertEqual(s.current, "v2")
        XCTAssertTrue(s.hasFailed("v3"))
        s.fail("v2")
        XCTAssertEqual(s.launchOrder(shipped: "v1", usable: all), ["v1"])
        s.fail("v1")
        XCTAssertEqual(s.launchOrder(shipped: "v1", usable: all), [], "the shipped copy failed too: the website")
        s.fail("v1")
        XCTAssertEqual(s.failed, ["v3", "v2", "v1"])
    }

    func testAdoptingANewVersionKeepsTheOneThatWorks() {
        var s = BundleState(build: 80)
        s.adopt("v2", active: "v1")  // v1 is the shipped copy, running now
        XCTAssertEqual(s.current, "v2")
        XCTAssertEqual(s.previous, "v1")
        XCTAssertEqual(s.keep(active: "v1"), ["v1", "v2"])
        s.adopt("v3", active: "v2")
        XCTAssertEqual([s.current, s.previous], ["v3", "v2"])
        s.adopt("v3", active: "v2")
        XCTAssertEqual([s.current, s.previous], ["v3", "v2"], "the same one again changes nothing")
        // v3 failed at launch, v2 is running; v4 arrives
        s.fail("v3")
        s.adopt("v4", active: "v2")
        XCTAssertEqual([s.current, s.previous], ["v4", "v2"])
        XCTAssertEqual(s.keep(active: "v2"), ["v4", "v2"], "v3 is deleted")
        // no bundle running (all failed, on the website): the newest that was ready is the one before
        var t = BundleState(current: "v5")
        t.adopt("v6", active: nil)
        XCTAssertEqual([t.current, t.previous], ["v6", "v5"])
        // the site goes back to the version that's running
        var u = BundleState(current: "v8", previous: "v7")
        u.adopt("v7", active: "v7")
        XCTAssertEqual(u.current, "v7")
    }

    func testProvenVersionsAndANewBuild() {
        var s = BundleState(current: "v2", previous: "v1", failed: ["v0"], build: 80)
        XCTAssertFalse(s.isProven("v2"))
        s.prove("v2")
        s.prove("v2")
        XCTAssertEqual(s.proven, ["v2"])
        XCTAssertEqual(s.forBuild(80), s, "the same build keeps everything")
        XCTAssertEqual(s.forBuild(81), BundleState(build: 81), "a new build starts from its own shipped copy")
        XCTAssertEqual(BundleState().forBuild(80), BundleState(build: 80))
    }

    func testSavedStateReadsBackAndOlderOrNewerFilesStillLoad() throws {
        let s = BundleState(current: "v2", previous: "v1", failed: ["v0"], proven: ["v2"], lastCheck: 1_763_373_600, build: 80)
        XCTAssertEqual(BundleState.decode(try XCTUnwrap(s.encoded())), s)
        XCTAssertEqual(BundleState.decode(Data("{}".utf8)), BundleState())
        XCTAssertEqual(BundleState.decode(Data(#"{"current":"v9","somethingNew":true}"#.utf8)), BundleState(current: "v9"))
        XCTAssertNil(BundleState.decode(Data("nope".utf8)))
    }

    // MARK: - When to check

    func testWhenToCheck() {
        let now = 1_763_373_600.0
        XCTAssertTrue(BundleCheck.due(now: now, last: nil, midWorkout: false), "never checked")
        XCTAssertFalse(BundleCheck.due(now: now, last: nil, midWorkout: true), "never during a workout")
        XCTAssertFalse(BundleCheck.due(now: now, last: now - 60, midWorkout: false))
        XCTAssertFalse(BundleCheck.due(now: now, last: now - 29 * 60, midWorkout: false))
        XCTAssertTrue(BundleCheck.due(now: now, last: now - 30 * 60, midWorkout: false))
        XCTAssertFalse(BundleCheck.due(now: now, last: now - 3 * 3600, midWorkout: true))
        XCTAssertTrue(BundleCheck.due(now: now, last: now + 500, midWorkout: false), "the clock went backward")
        XCTAssertEqual(BundleCheck.startSeconds, 8)
        XCTAssertEqual(BundleCheck.moveSeconds, 10)
    }

    // MARK: - Ranges (sounds and video ask for parts)

    func testByteRanges() {
        XCTAssertNil(ByteRange.parse(nil, size: 100))
        XCTAssertEqual(ByteRange.parse("bytes=0-1", size: 100), 0...1)
        XCTAssertEqual(ByteRange.parse("bytes=10-", size: 100), 10...99)
        XCTAssertEqual(ByteRange.parse("bytes=-20", size: 100), 80...99)
        XCTAssertEqual(ByteRange.parse("bytes=-500", size: 100), 0...99)
        XCTAssertEqual(ByteRange.parse("bytes=90-500", size: 100), 90...99)
        XCTAssertEqual(ByteRange.parse("Bytes=5-5", size: 100), 5...5)
        XCTAssertNil(ByteRange.parse("bytes=100-", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=5-2", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=0-1,5-6", size: 100))
        XCTAssertNil(ByteRange.parse("items=0-1", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=0-1", size: 0))
        XCTAssertNil(ByteRange.parse("bytes=-0", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=a-b", size: 100))
    }

    // MARK: - Where the bundled page is, and what may talk to Virt from it

    func testBundledNavigation() {
        let u = { (s: String) in URL(string: s) }
        XCTAssertEqual(Navigation.bundledHome.absoluteString, "virt-app://train/")
        XCTAssertEqual(Navigation.bundledGuestHome.absoluteString, "virt-app://train/try")
        XCTAssertTrue(Navigation.isBundled(u("virt-app://train/")))
        XCTAssertTrue(Navigation.isBundled(u("virt-app://train/_train/immutable/x.js")))
        XCTAssertFalse(Navigation.isBundled(u("virt-app://other/")))
        XCTAssertFalse(Navigation.isBundled(u("https://train/")))
        XCTAssertFalse(Navigation.isBundled(nil))

        // bundled: the bundle's pages are inside, everything on the web goes to Safari
        XCTAssertEqual(Navigation.choose(u("virt-app://train/"), mainFrame: true, door: .friend, bundled: true), .load)
        XCTAssertEqual(Navigation.choose(u("virt-app://train/privacy"), mainFrame: true, door: .friend, bundled: true), .load)
        XCTAssertEqual(Navigation.choose(u("virt-app://elsewhere/"), mainFrame: true, door: .friend, bundled: true), .block)
        XCTAssertEqual(Navigation.choose(u("https://train.time2play.live/live/train/export"), mainFrame: true, door: .friend, bundled: true), .openOutside)
        XCTAssertEqual(Navigation.choose(u("https://example.com/"), mainFrame: true, door: .friend, bundled: true), .openOutside)
        XCTAssertEqual(Navigation.choose(u("https://studio.tyleralocke.com/training"), mainFrame: true, door: .friend, bundled: true), .openOutside)
        XCTAssertEqual(Navigation.choose(u("https://www.youtube.com/embed/x"), mainFrame: false, door: .friend, bundled: true), .load, "an embedded frame")
        XCTAssertEqual(Navigation.choose(u("mailto:someone@example.com"), mainFrame: true, door: .friend, bundled: true), .openOutside)
        // not bundled: the scheme is never loaded, and everything else is as before
        XCTAssertEqual(Navigation.choose(u("virt-app://train/"), mainFrame: true, door: .friend), .block)
        XCTAssertEqual(Navigation.choose(u("virt-app://train/"), mainFrame: true, door: .tyler, bundled: true), .block, "never the studio's door")
        XCTAssertEqual(Navigation.choose(u("https://train.time2play.live/"), mainFrame: true, door: .friend), .load)

        XCTAssertTrue(Navigation.isTraining(u("virt-app://train/"), door: .friend, bundled: true))
        XCTAssertTrue(Navigation.isTraining(u("virt-app://train/try"), door: .friend, bundled: true))
        XCTAssertFalse(Navigation.isTraining(u("virt-app://train/privacy"), door: .friend, bundled: true))
        XCTAssertFalse(Navigation.isTraining(u("https://train.time2play.live/"), door: .friend, bundled: true))
        XCTAssertFalse(Navigation.isTraining(u("virt-app://train/"), door: .friend), "only in bundled mode")
        XCTAssertTrue(Navigation.isTraining(u("https://train.time2play.live/"), door: .friend))

        XCTAssertEqual(Navigation.todayAction(current: u("virt-app://train/"), midWorkout: false, door: .friend, bundled: true), .stay)
        XCTAssertEqual(Navigation.todayAction(current: u("virt-app://train/privacy"), midWorkout: false, door: .friend, bundled: true), .loadHome)
        XCTAssertEqual(Navigation.todayAction(current: u("virt-app://train/privacy"), midWorkout: true, door: .friend, bundled: true), .stay)
    }

    func testASiteLinkToABundlePageOpensFromTheBundle() {
        let pages: Set<String> = ["/", "/try", "/privacy", "/terms"]
        let isPage = { (p: String) in pages.contains(p) }
        let u = { (s: String) in URL(string: s) }
        XCTAssertEqual(Navigation.bundledPage(for: u("https://train.time2play.live/privacy"), isPage: isPage)?.absoluteString, "virt-app://train/privacy")
        XCTAssertEqual(Navigation.bundledPage(for: u("https://train.time2play.live/"), isPage: isPage)?.absoluteString, "virt-app://train/")
        XCTAssertEqual(Navigation.bundledPage(for: u("https://train.time2play.live"), isPage: isPage)?.absoluteString, "virt-app://train/")
        XCTAssertNil(Navigation.bundledPage(for: u("https://train.time2play.live/live/train/export"), isPage: isPage))
        XCTAssertNil(Navigation.bundledPage(for: u("https://example.com/privacy"), isPage: isPage))
        XCTAssertNil(Navigation.bundledPage(for: u("http://train.time2play.live/privacy"), isPage: isPage))
        XCTAssertNil(Navigation.bundledPage(for: nil, isPage: isPage))
    }

    func testWhoMayTalkToVirt() {
        XCTAssertTrue(Navigation.isFriendOrigin(scheme: "https", host: "train.time2play.live", bundled: false))
        XCTAssertTrue(Navigation.isFriendOrigin(scheme: "https", host: "train.time2play.live", bundled: true))
        XCTAssertTrue(Navigation.isFriendOrigin(scheme: "virt-app", host: "train", bundled: true))
        XCTAssertFalse(Navigation.isFriendOrigin(scheme: "virt-app", host: "train", bundled: false), "only in bundled mode")
        XCTAssertFalse(Navigation.isFriendOrigin(scheme: "virt-app", host: "other", bundled: true))
        XCTAssertFalse(Navigation.isFriendOrigin(scheme: "http", host: "train.time2play.live", bundled: true))
        XCTAssertFalse(Navigation.isFriendOrigin(scheme: "https", host: "train", bundled: true))
        XCTAssertFalse(Navigation.isFriendOrigin(scheme: "https", host: "example.com", bundled: true))
        XCTAssertEqual(Navigation.appBoundDomains.last, "virt-app:", "the scheme, as WebKit reads it (a trailing colon)")
    }

    func testScriptsForTheBundledPage() throws {
        let token = String(repeating: "ab12", count: 8)
        let plain = try XCTUnwrap(FriendSignIn.handoverScript(token: token))
        XCTAssertFalse(plain.contains("virt-app"), "outside bundled mode the session goes to the site only, as before")
        let s = try XCTUnwrap(FriendSignIn.handoverScript(token: token, bundled: true))
        XCTAssertTrue(s.contains("window.T2P_SESSION = '\(token)'"))
        XCTAssertTrue(s.contains("location.protocol === 'virt-app:' && location.host === 'train'"), "the bundled page")
        XCTAssertTrue(s.contains("location.protocol === 'https:' && location.hostname === 'train.time2play.live'"), "and the site, nothing else")
        XCTAssertNil(FriendSignIn.handoverScript(token: "abcdefghijklmnop'+x+'", bundled: true))

        XCTAssertFalse(FriendSignIn.signOutWatchScript.contains("virt-app"))
        XCTAssertEqual(FriendSignIn.signOutWatch(bundled: false), FriendSignIn.signOutWatchScript)
        let w = FriendSignIn.signOutWatch(bundled: true)
        XCTAssertTrue(w.contains("virt-app:") && w.contains("[data-sign-out]") && w.contains("virtAccount"))

        XCTAssertTrue(PageStart.apiBaseScript.contains("window.T2P_API_BASE = 'https://train.time2play.live'"))
        XCTAssertTrue(PageStart.apiBaseScript.contains("location.protocol === 'virt-app:' && location.host === 'train'"), "only on the bundled page")

        let start = PageStart.script(build: 81)
        XCTAssertTrue(start.contains("app: 'virt', version: 2, sounds: ['lead-in', 'zero', 'set', 'finish'], settings: true, build: 81"))
        XCTAssertTrue(start.contains("if (location.protocol === 'virt-app:') app.bundled = true;"))
        XCTAssertTrue(start.contains("window.kineticApp = Object.freeze(app)"))
    }
}
