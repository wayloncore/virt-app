import XCTest
@testable import VirtCore

/// The sound styles (Nov 27: back to the three, one plain list): the names the picker and the page show, which file
/// each cue plays, that every one of those files is in the app, and that a style saved by a Nov 27 build that's gone
/// now reads back cleanly.
final class SoundStyleTests: XCTestCase {
    func testTheThreeInDisplayOrder() {
        XCTAssertEqual(SoundStyle.allCases.map(\.name), ["Chime", "Digital", "Classic"])
        XCTAssertEqual(SoundStyle.allCases.map(\.rawValue), ["chime", "digital", "classic"])
        for s in SoundStyle.allCases {
            XCTAssertFalse(s.name.lowercased().split(separator: " ").contains("buzz"), "never the word buzz alone")
            XCTAssertFalse(s.detail.isEmpty)
        }
    }

    func testStoredValuesFromBeforeStillRead() {
        XCTAssertEqual(SoundStyle(stored: "chime"), .chime)
        XCTAssertEqual(SoundStyle(stored: "digital"), .digital)
        XCTAssertEqual(SoundStyle(stored: "classic"), .classic)
        XCTAssertEqual(SoundStyle(stored: nil), .standard)
        XCTAssertEqual(SoundStyle(stored: "whistle"), .standard, "an unknown style falls back")
        for s in SoundStyle.allCases { XCTAssertEqual(SoundStyle(stored: s.rawValue), s) }
    }

    /// A phone that saved one of the 14 tone styles (builds from Nov 27, up to 95): Digital up comes back as Digital,
    /// every other one as Chime. Nothing crashes, and the page is told the kept style.
    func testARemovedToneStyleFallsBack() {
        XCTAssertEqual(SoundStyle.removed.count, 14)
        XCTAssertEqual(SoundStyle(stored: "digital-up"), .digital)
        for id in SoundStyle.removed where id != "digital-up" {
            XCTAssertEqual(SoundStyle(stored: id), .chime, id)
            XCTAssertNil(SoundStyle(rawValue: id), "\(id) is gone")
        }
        let prefs = AppPrefs(sounds: true, soundStyle: SoundStyle(stored: "quest-jingle"), reminders: false, reminderLine: "",
                             notifications: true)
        XCTAssertTrue(prefs.json.contains("\"soundStyle\":\"chime\""), prefs.json)
    }

    func testFiles() {
        XCTAssertEqual(SoundStyle.digital.file(.go), SoundStyle.startFile)
        XCTAssertEqual(SoundStyle.digital.file(.rest), "virt-digital-rest.caf")
        XCTAssertEqual(SoundStyle.digital.file(.leadIn), "virt-digital-tick.caf")
        XCTAssertEqual(SoundStyle.digital.file(.set), "virt-digital-set.caf")
        XCTAssertEqual(SoundStyle.digital.file(.finish), "virt-digital-finish.caf")
        XCTAssertEqual(SoundStyle.chime.file(.go), SoundStyle.startFile)
        XCTAssertEqual(SoundStyle.chime.file(.rest), "virt-chime-rest.caf")
        XCTAssertEqual(SoundStyle.classic.file(.go), "virt-chime.wav")
        XCTAssertEqual(SoundStyle.classic.file(.rest), "virt-chime.wav")
        for c in [SoundCue.leadIn, .set, .finish] { XCTAssertEqual(SoundStyle.classic.file(c), SoundStyle.chime.file(c)) }
        XCTAssertEqual(SoundStyle.startLead, 3)
        for s in SoundStyle.allCases {
            for c in SoundCue.allCases { XCTAssertEqual(s.lead(c), c.isZero ? 3 : 0, "\(s.rawValue) \(c.rawValue)") }
        }
        XCTAssertEqual(SoundStyle.digital.countInTick(.rest), "virt-digital-tick.caf", "Digital counts in with its own tick")
        XCTAssertEqual(SoundStyle.classic.countInTick(.go), "virt-chime-tick.caf")
        XCTAssertNil(SoundStyle.digital.countInTick(.go), "the green light is its own count-in")
        XCTAssertNil(SoundStyle.chime.countInTick(.set))
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
        // the tone styles' files went with them
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("App/Sounds").path)) ?? []
        XCTAssertFalse(left.contains { $0.hasSuffix("-zero.caf") }, "\(left)")
    }

    func testTheListForThePage() {
        let list = try! JSONSerialization.jsonObject(with: SoundStyle.listJSON.data(using: .utf8)!) as! [[String: String]]
        XCTAssertEqual(list, [
            ["id": "chime", "name": "Chime", "group": ""],
            ["id": "digital", "name": "Digital", "group": ""],
            ["id": "classic", "name": "Classic", "group": ""],
        ], "one plain list: the page shows no group title for an empty group")
    }
}
