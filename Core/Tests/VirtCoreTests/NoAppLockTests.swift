import XCTest
@testable import VirtCore

/// Virt has no lock of its own (Tyler, Nov 28: "the phone might need the Face ID to log in with Apple, but not to log
/// into the app ever"). Read from the source, so this runs on Linux too: nothing in the app asks for Face ID or the
/// passcode, its Info.plist doesn't ask to use Face ID, nothing offers Lock after any more, and build 100's stored
/// Lock after is neither read nor cleared, so a rollback to build 100 still finds it. Sign in with Apple's own sheet is
/// Apple's, not Virt's, and isn't affected.
final class NoAppLockTests: XCTestCase {
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

    func testNothingAsksForFaceIDOrThePasscode() throws {
        let files = sources(["App", "Shared", "Widget"])
        try XCTSkipIf(files.isEmpty, "the app's sources aren't next to the package")
        for f in files {
            for asks in ["import LocalAuthentication", "LAContext", "evaluatePolicy", "deviceOwnerAuthentication", "biometryType"] {
                XCTAssertFalse(f.text.contains(asks), "\(f.name) uses \(asks)")
            }
        }
    }

    func testInfoPlistDoesNotAskToUseFaceID() throws {
        let spec = try? String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        try XCTSkipIf(spec == nil, "project.yml isn't next to the package")
        XCTAssertFalse(spec?.contains("NSFaceIDUsageDescription") ?? true, "nothing in Virt uses Face ID")
    }

    func testLockAfterIsGoneAndBuild100sValueIsLeftAlone() throws {
        let files = sources(["App", "Shared", "Widget"])
        try XCTSkipIf(files.isEmpty, "the app's sources aren't next to the package")
        for f in files {
            XCTAssertFalse(f.text.contains("\"lock.after\""), "\(f.name) reads or clears build 100's stored Lock after")
            XCTAssertFalse(f.text.contains("\"Lock after"), "\(f.name) still offers Lock after")
            XCTAssertFalse(f.text.contains("lockAfter"), "\(f.name) still sends or reads lockAfter")
        }
    }
}
