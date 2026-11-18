import XCTest
@testable import VirtCore

/// Commands for the page (Siri, widgets, reminders), the queue that holds them until Training is ready, Virt's own
/// links, the offline choice, and the sounds.
final class PageCommandTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_021_200)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }

    func testScripts() {
        XCTAssertEqual(PageCommand.startToday.script, "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: 'startToday' }));")
        XCTAssertEqual(PageCommand.rest(seconds: 90).script,
                       "window.dispatchEvent(new CustomEvent('kinetic:command', { detail: { command: 'rest', seconds: 90 } }));")
        XCTAssertEqual(PageCommand.timer(.pause).script, TimerCommand.pause.script)
    }

    func testRestLengths() {
        XCTAssertEqual(RestRequest.seconds(nil), 90)
        XCTAssertEqual(RestRequest.seconds(nil, preset: 45), 45)
        XCTAssertEqual(RestRequest.seconds(60, preset: 45), 60, "the number he gave wins")
        XCTAssertEqual(RestRequest.seconds(1), 5)
        XCTAssertEqual(RestRequest.seconds(99_999), 1800)
    }

    func testCommandsWaitForThePage() {
        var q = CommandQueue()
        XCTAssertEqual(q.add(.startToday(since: s(0)), now: s(0)), [], "not loaded yet")
        XCTAssertEqual(q.add(.rest(endsAt: s(92)), now: s(1)), [])
        XCTAssertEqual(q.pageReady(now: s(10)), [.startToday, .rest(seconds: 82)], "the rest keeps its end")
        XCTAssertEqual(q.drain(now: s(11)), [], "sent once")
        XCTAssertEqual(q.add(.rest(endsAt: s(100)), now: s(40)), [.rest(seconds: 60)], "ready: straight through")
        q.pageLoading()
        XCTAssertEqual(q.add(.startToday(since: s(50)), now: s(50)), [])
        XCTAssertEqual(q.add(.startToday(since: s(55)), now: s(55)), [])
        XCTAssertEqual(q.pageReady(now: s(56)), [.startToday], "one start, not two")
    }

    func testStaleCommandsAreDropped() {
        var q = CommandQueue()
        _ = q.add(.startToday(since: s(0)), now: s(0))
        _ = q.add(.rest(endsAt: s(30)), now: s(0))
        XCTAssertEqual(q.pageReady(now: s(CommandQueue.waitLimit + 1)), [], "a slow sign-in doesn't start a surprise workout")
        _ = q.add(.rest(endsAt: s(400)), now: s(390))
        XCTAssertTrue(q.waiting.isEmpty)
    }

    func testLinks() {
        XCTAssertEqual(AppLink.parse(URL(string: "virt://today")!), .today)
        XCTAssertEqual(AppLink.parse(URL(string: "virt://start")!), .start)
        XCTAssertEqual(AppLink.parse(URL(string: "virt://rest?seconds=45")!), .rest(seconds: 45))
        XCTAssertEqual(AppLink.parse(URL(string: "virt://rest")!), .rest(seconds: 90))
        XCTAssertEqual(AppLink.parse(URL(string: "VIRT://Settings")!), .settings)
        XCTAssertNil(AppLink.parse(URL(string: "virt://launch-missiles")!))
        XCTAssertNil(AppLink.parse(URL(string: "https://studio.tyleralocke.com/training")!))
        for l in [AppLink.today, .start, .rest(seconds: 30), .settings] { XCTAssertEqual(AppLink.parse(l.url), l) }
        XCTAssertEqual(AppLink.quickAction("com.tyleralocke.virt.rest"), .rest(seconds: 90))
        XCTAssertNil(AppLink.quickAction("other"))
    }

    func testOpeningToToday() {
        let u = { (s: String) in URL(string: s) }
        XCTAssertEqual(Navigation.todayAction(current: u("https://studio.tyleralocke.com/training"), midWorkout: false), .stay)
        XCTAssertEqual(Navigation.todayAction(current: u("https://studio.tyleralocke.com/training/history"), midWorkout: false), .loadHome)
        XCTAssertEqual(Navigation.todayAction(current: u("https://studio.tyleralocke.com/training/history"), midWorkout: true), .stay,
                       "never pulled off a workout")
        XCTAssertEqual(Navigation.todayAction(current: u("https://studio.tyleralocke.com/zareli"), midWorkout: false), .loadHome)
        XCTAssertEqual(Navigation.todayAction(current: u("https://proud-unit-177a.cloudflareaccess.com/cdn-cgi/access/login/x"), midWorkout: false), .stay)
        XCTAssertEqual(Navigation.todayAction(current: nil, midWorkout: false), .stay)
        XCTAssertLessThanOrEqual(Navigation.appBoundDomains.count, 10, "iOS allows ten")
        for host in ["studio.tyleralocke.com", "proud-unit-177a.cloudflareaccess.com"] {
            XCTAssertTrue(Navigation.appBoundDomains.contains(host), host)
        }
    }

    func testOfflineChoice() {
        XCTAssertEqual(OfflinePolicy.choose(urlErrorCode: -999, hasPage: false, triedCache: false), .ignore)
        XCTAssertEqual(OfflinePolicy.choose(urlErrorCode: nil, hasPage: false, triedCache: false), .ignore)
        XCTAssertEqual(OfflinePolicy.choose(urlErrorCode: -1009, hasPage: true, triedCache: false), .keepPage,
                       "a page that's up stays up (Training works offline)")
        XCTAssertEqual(OfflinePolicy.choose(urlErrorCode: -1009, hasPage: false, triedCache: false), .tryCache)
        XCTAssertEqual(OfflinePolicy.choose(urlErrorCode: -1008, hasPage: false, triedCache: true), .showOffline)
    }

    func testSounds() {
        XCTAssertEqual(SoundCue.zero(after: .rest), .go)
        XCTAssertEqual(SoundCue.zero(after: .intervalRest), .go)
        XCTAssertEqual(SoundCue.zero(after: .work), .rest)
        XCTAssertEqual(SoundCue.zero(after: .hold), .rest)
        XCTAssertEqual(SoundStyle.chime.file(.go), "virt-chime-go.caf")
        XCTAssertEqual(SoundStyle.digital.file(.leadIn), "virt-digital-tick.caf")
        XCTAssertEqual(SoundStyle.classic.file(.rest), "virt-chime.wav")
        XCTAssertEqual(SoundStyle.classic.file(.set), "virt-chime-set.caf")
        XCTAssertEqual(SoundStyle(stored: "digital"), .digital)
        XCTAssertEqual(SoundStyle(stored: "from-the-future"), .standard)
        XCTAssertEqual(SoundStyle(stored: nil), .standard)
        XCTAssertEqual(ZeroMix.choose(otherAudioPlaying: true), .duck)
        XCTAssertEqual(ZeroMix.choose(otherAudioPlaying: false), .mix)
    }

    func testLeadIn() {
        XCTAssertEqual(LeadIn.ticks(zero: s(60), now: s(0), length: 60), [s(57), s(58), s(59)])
        XCTAssertEqual(LeadIn.ticks(zero: s(60), now: s(57.5), length: 60), [s(58), s(59)])
        XCTAssertEqual(LeadIn.ticks(zero: s(5), now: s(0), length: 5), [], "too short for a lead-in")
        XCTAssertEqual(LeadIn.ticks(zero: s(60), now: s(0), length: nil).count, 3)
    }
}
