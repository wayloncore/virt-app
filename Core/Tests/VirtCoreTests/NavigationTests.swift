import XCTest
@testable import VirtCore

/// The studio and its sign-in open inside the app; everything else a link opens goes to Safari.
final class NavigationTests: XCTestCase {
    func choose(_ s: String, main: Bool = true) -> Navigation.Choice { Navigation.choose(URL(string: s), mainFrame: main) }

    func testStudioAndSignInStayInside() {
        XCTAssertEqual(choose("https://studio.tyleralocke.com/training"), .load)
        XCTAssertEqual(choose("https://tyleralocke.com/library"), .load)
        XCTAssertEqual(choose("https://proud-unit-177a.cloudflareaccess.com/cdn-cgi/access/login/studio.tyleralocke.com?kid=x"), .load)
        XCTAssertEqual(choose("https://studio.tyleralocke.com/cdn-cgi/access/authorized?token=x"), .load)
        XCTAssertEqual(choose("https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x"), .load)
        XCTAssertEqual(choose("https://accounts.google.com/o/oauth2/auth"), .load, "an identity provider Access might use")
        XCTAssertEqual(choose("about:blank"), .load)
    }

    func testOtherPagesGoOutside() {
        XCTAssertEqual(choose("https://www.youtube.com/watch?v=x"), .openOutside)
        XCTAssertEqual(choose("https://github.com/wayloncore"), .openOutside)
        XCTAssertEqual(choose("https://github.com/login"), .load)
        XCTAssertEqual(choose("https://eviltyleralocke.com/"), .openOutside, "a look-alike host isn't the studio")
        XCTAssertEqual(choose("mailto:someone@example.com"), .openOutside)
        XCTAssertEqual(choose("javascript:alert(1)"), .block)
        XCTAssertEqual(choose("file:///etc/passwd"), .block)
    }

    func testFramesLoadWhereTheyAre() {
        XCTAssertEqual(choose("https://www.youtube.com/embed/x", main: false), .load)
    }

    func testWhichPage() {
        XCTAssertTrue(Navigation.isTraining(URL(string: "https://studio.tyleralocke.com/training#today")))
        XCTAssertFalse(Navigation.isTraining(URL(string: "https://studio.tyleralocke.com/live")))
        XCTAssertTrue(Navigation.isSignIn(URL(string: "https://proud-unit-177a.cloudflareaccess.com/")))
        XCTAssertEqual(Navigation.home.absoluteString, "https://studio.tyleralocke.com/training")
    }

    func testTheGuestPageIsTrainingOnTheFriendsDoor() {
        XCTAssertEqual(Navigation.guestHome.absoluteString, "https://train.time2play.live/try")
        XCTAssertTrue(Navigation.isTraining(Navigation.guestHome, door: .friend))
        XCTAssertFalse(Navigation.isTraining(URL(string: "https://train.time2play.live/privacy"), door: .friend))
        XCTAssertTrue(BridgeMessage.isGuestSignIn(object: ["type": "signIn", "from": "guest"]))
        XCTAssertFalse(BridgeMessage.isGuestSignIn(object: ["type": "today"]))
        XCTAssertFalse(BridgeMessage.isGuestSignIn(object: "signIn"))
    }
}
