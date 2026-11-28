import XCTest
@testable import VirtCore

/// The sound styles (Tyler, Nov 27: more tones): the names and groups the picker and the page show, which file each
/// cue plays, and that every one of those files is in the app.
final class SoundStyleTests: XCTestCase {
    func testNamesAndGroupsInDisplayOrder() {
        XCTAssertEqual(SoundStyle.Group.allCases.map(\.rawValue), ["Classic", "Clean", "Playful"])
        XCTAssertEqual(SoundStyle.styles(in: .classic).map(\.name), ["Chime", "Classic"])
        XCTAssertEqual(SoundStyle.styles(in: .clean).map(\.name),
                       ["Digital", "Digital up", "Glass", "Sonar", "Synth rise", "Watch beeps", "Marimba", "Ring bell", "Buzzer horn"])
        XCTAssertEqual(SoundStyle.styles(in: .playful).map(\.name),
                       ["Arcade", "Level up", "Coin pickup", "Victory", "Bounce", "Quest jingle"])
        // allCases is the groups one after another, so the page's list is already in display order
        XCTAssertEqual(SoundStyle.allCases, SoundStyle.Group.allCases.flatMap { SoundStyle.styles(in: $0) })
        XCTAssertEqual(SoundStyle.allCases.count, 17)
        XCTAssertEqual(Set(SoundStyle.allCases.map(\.name)).count, 17, "every name differs")
        for s in SoundStyle.allCases {
            XCTAssertFalse(s.name.lowercased().split(separator: " ").contains("buzz"), "never the word buzz alone")
        }
    }

    func testStoredValuesFromBeforeStillRead() {
        XCTAssertEqual(SoundStyle(stored: "chime"), .chime)
        XCTAssertEqual(SoundStyle(stored: "digital"), .digital)
        XCTAssertEqual(SoundStyle(stored: "classic"), .classic)
        XCTAssertEqual(SoundStyle(stored: "quest-jingle"), .questJingle)
        XCTAssertEqual(SoundStyle(stored: "whistle"), .standard, "an unknown style falls back")
        for s in SoundStyle.allCases { XCTAssertEqual(SoundStyle(stored: s.rawValue), s) }
    }

    func testFiles() {
        // Digital exactly as before (Tyler, Nov 27: "I like the digital one that's already on there")
        XCTAssertEqual(SoundStyle.digital.file(.go), SoundStyle.startFile)
        XCTAssertEqual(SoundStyle.digital.file(.rest), "virt-digital-rest.caf")
        XCTAssertEqual(SoundStyle.digital.file(.leadIn), "virt-digital-tick.caf")
        XCTAssertEqual(SoundStyle.digital.file(.set), "virt-digital-set.caf")
        XCTAssertEqual(SoundStyle.digital.file(.finish), "virt-digital-finish.caf")
        XCTAssertEqual(SoundStyle.digital.lead(.go), SoundStyle.startLead)
        XCTAssertEqual(SoundStyle.startLead, 3)
        XCTAssertEqual(SoundStyle.digital.countInTick(.rest), "virt-digital-tick.caf", "Digital counts in with its own tick")
        // a tone style: its tone at both zeros after Chime's tick three times (Nov 27), Chime's other cues
        for s in SoundStyle.allCases where s.isTone {
            XCTAssertEqual(s.file(.go), "virt-\(s.rawValue)-zero.caf")
            XCTAssertEqual(s.file(.rest), s.file(.go))
            for c in [SoundCue.leadIn, .set, .finish] { XCTAssertEqual(s.file(c), SoundStyle.chime.file(c)) }
            for c in SoundCue.allCases { XCTAssertEqual(s.lead(c), c.isZero ? 3 : 0, "\(s.rawValue) \(c.rawValue)") }
            XCTAssertEqual(s.countInTick(.go), "virt-chime-tick.caf")
            XCTAssertEqual(s.countInTick(.rest), "virt-chime-tick.caf")
            XCTAssertNil(s.countInTick(.set))
        }
        XCTAssertEqual(SoundStyle.allCases.filter(\.isTone).count, 14)
        XCTAssertEqual(SoundStyle.digitalUp.file(.rest), "virt-digital-up-zero.caf", "Digital up: its own style")
        XCTAssertFalse(SoundStyle.chime.isTone || SoundStyle.classic.isTone || SoundStyle.digital.isTone)
    }

    func testEveryFileIsInTheApp() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for s in SoundStyle.allCases {
            for f in s.files {
                let dir = f == "virt-chime.wav" ? "App" : "App/Sounds"
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(dir)/\(f)").path),
                              "\(s.rawValue): \(f)")
            }
        }
    }

    func testTheListForThePage() {
        let list = try! JSONSerialization.jsonObject(with: SoundStyle.listJSON.data(using: .utf8)!) as! [[String: String]]
        XCTAssertEqual(list.count, SoundStyle.allCases.count)
        XCTAssertEqual(list[2], ["id": "digital", "name": "Digital", "group": "Clean"])
        XCTAssertEqual(list.last, ["id": "quest-jingle", "name": "Quest jingle", "group": "Playful"])
    }
}
