import CryptoKit
import Foundation
import Network
import UIKit
import VirtCore

/// One version of Training's screens on this phone, every file there: `manifest.json` and, under `files/`, each file
/// at its own path.
struct ReadyBundle: Sendable {
    let manifest: BundleManifest
    let root: URL

    var version: String { manifest.version }
    func url(of file: BundleFile) -> URL { root.appendingPathComponent("files" + file.path) }
}

/// Training's screens inside the app (wayloncore/tyleralocke#822; the rules are VirtCore's TrainBundle.swift).
///
/// - The **shipped copy** is in the app's resources (`Bundle/`, put there at build time by scripts/fetch_bundle.py).
///   A build with no shipped copy has no bundle at all: it loads the website exactly as Virt always has, and never
///   downloads one.
/// - **Downloaded versions** live in Application Support/Bundles/<version>/ (not backed up to iCloud: they can
///   always be fetched again).
/// - At launch the newest ready version is chosen, and that's the one served until the app is closed. A newer one
///   that arrives meanwhile is used **from the next launch, never swapped under a running page**.
/// - A version that doesn't start (ShellController's 8-second watch) is marked failed and the one before it is
///   used, then the shipped copy, then the website.
///
/// Only train.time2play.live is ever contacted, over https, with no cookies. On the main thread; the file checks
/// and downloads of an update run off it.
@MainActor final class BundleStore {
    static let shared = BundleStore()

    /// The version being served this launch; nil means no bundle (the website, as before).
    private(set) var active: ReadyBundle? { didSet { BundleMode.on = active != nil } }
    /// The ones to fall back to, in order.
    private var fallbacks: [ReadyBundle] = []
    /// Every version that's whole on this phone, the shipped one included.
    private var known: [String: ReadyBundle] = [:]
    private var state = BundleState()
    private let shipped: ReadyBundle?
    /// This app's build number (CFBundleVersion), which the manifest's `minApp` is checked against.
    let build: Int
    private let dir: URL
    private let testing: Bool
    private var updating = false
    private let monitor = NWPathMonitor()
    /// For the test build's status line: what happened to a version that didn't start.
    private(set) var note = ""

    var bundled: Bool { active != nil }

    /// True while the phone has a way out to the network (the move from the old way waits for one).
    var online: Bool { monitor.currentPath.status == .satisfied }

    private init() {
        let info = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        build = Int(info.split(separator: ".").first.map(String.init) ?? "") ?? 0
        let fm = FileManager.default
        let args = ProcessInfo.processInfo.arguments
        var isTest = false
        var fixture: ReadyBundle?
        #if DEBUG
        // the test build never reads the embedded copy or the network: `-uitest-bundle` makes a tiny bundle of its
        // own, and without it there is none, so every other test runs the website path as before
        if args.contains("-uitest") {
            isTest = true
            if args.contains("-uitest-bundle") { fixture = BundleFixture.make(html: ProcessInfo.processInfo.environment["VIRT_TEST_HTML"]) }
        }
        #endif
        _ = args
        testing = isTest
        if isTest {
            dir = fm.temporaryDirectory.appendingPathComponent("virt-test-bundles")
            shipped = fixture
        } else {
            let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? fm.temporaryDirectory
            dir = support.appendingPathComponent("Bundles")
            shipped = Bundle.main.resourceURL.flatMap { BundleStore.load(root: $0.appendingPathComponent("Bundle")) }
        }
        monitor.start(queue: .global(qos: .utility))
        guard let shipped else { return }  // no shipped copy: no bundle, and nothing is ever downloaded

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var folder = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)

        if !isTest, let d = try? Data(contentsOf: stateFile), let s = BundleState.decode(d) { state = s }
        state = state.forBuild(build)
        if shipped.manifest.minApp <= build { known[shipped.version] = shipped }
        for v in [state.current, state.previous].compactMap({ $0 }) where known[v] == nil && BundlePath.safeVersion(v) {
            if let b = BundleStore.load(root: dir.appendingPathComponent(v)), b.version == v, b.manifest.minApp <= build { known[v] = b }
        }
        let order = state.launchOrder(shipped: shipped.version, usable: Set(known.keys)).compactMap { known[$0] }
        active = order.first
        fallbacks = Array(order.dropFirst())
        BundleMode.on = active != nil  // (a property's didSet doesn't run inside init)
        save()
        prune(keepPartial: nil)
    }

    // MARK: - Starting, and falling back

    /// True while the active version has never spoken on the bridge: the shell watches its first load.
    var needsWatch: Bool { active.map { !state.isProven($0.version) } ?? false }

    /// The active version's page posted a bridge message: it works, and isn't watched again.
    func proved() {
        guard let a = active, !state.isProven(a.version) else { return }
        state.prove(a.version)
        save()
    }

    /// The active version didn't start: it's never tried again, and the one before it (then the shipped copy)
    /// takes over. With none left there's no bundle, and the shell loads the website.
    func failActive() {
        guard let a = active else { return }
        state.fail(a.version)
        known[a.version] = nil
        note = " (failed \(a.version))"
        active = fallbacks.isEmpty ? nil : fallbacks.removeFirst()
        save()
    }

    /// The web view refused the bundle's page outright: no bundle for the rest of this launch. Nothing is marked
    /// failed; the next launch tries again.
    func giveUp() {
        guard active != nil else { return }
        note = " (would not load)"
        fallbacks = []
        active = nil
    }

    // MARK: - Updating

    /// Asks the website for a newer manifest (VirtCore's rule: at most every 30 minutes, never during a workout) and
    /// fetches what's missing. Called at launch and when the app comes forward.
    func checkForUpdate(midWorkout: Bool) {
        guard shipped != nil, !testing, !updating else { return }
        let now = Date().timeIntervalSince1970
        guard BundleCheck.due(now: now, last: state.lastCheck, midWorkout: midWorkout) else { return }
        updating = true
        state.lastCheck = now
        save()
        let background = UIApplication.shared.beginBackgroundTask(withName: "virt.bundle")
        Task { @MainActor in
            let ok = await self.update()
            // no answer (no signal, a download cut short): try again in five minutes, not thirty
            if !ok { self.state.lastCheck = now - BundleCheck.every + 300; self.save() }
            self.updating = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    /// One update, start to finish. False when it couldn't be finished this time.
    private func update() async -> Bool {
        let session = BundleStore.session()
        defer { session.finishTasksAndInvalidate() }
        guard let raw = await BundleStore.fetch(BundleManifest.url, session), let manifest = BundleManifest.parse(raw) else { return false }
        let (decision, have, staging) = plan(manifest)
        switch decision {
        case .nothing, .tooOld:
            return true
        case .download:
            break
        }
        guard let staging else {  // it's already whole on the phone: just make it the newest
            adopt(manifest.version)
            return true
        }
        guard await BundleStore.stage(manifest, raw: raw, have: have, into: staging, session: session) else { return false }
        return finish(manifest.version, staging: staging)
    }

    /// What a fresh manifest means here, where each file already on the phone is (by hash), and the folder to build
    /// the new version in (nil when there's nothing to build).
    private func plan(_ m: BundleManifest) -> (BundleUpdate, [String: URL], URL?) {
        var have: [String: URL] = [:]
        for b in known.values { for f in b.manifest.files where have[f.sha256] == nil { have[f.sha256] = b.url(of: f) } }
        let decision = BundleUpdate.decide(state: state, shipped: shipped?.version, usable: Set(known.keys), build: build,
                                           manifest: m, have: Set(have.keys))
        guard case .download = decision, known[m.version] == nil else { return (decision, have, nil) }
        let staging = dir.appendingPathComponent(BundleStore.partial + m.version)
        prune(keepPartial: staging.lastPathComponent)
        return (decision, have, staging)
    }

    /// Every file is in the staging folder and checked: it becomes the version's own folder, and the next launch
    /// uses it.
    private func finish(_ version: String, staging: URL) -> Bool {
        let fm = FileManager.default
        let home = dir.appendingPathComponent(version)
        // never the folder being served right now (it can't be: a version that's whole is never staged again)
        guard active?.root.standardizedFileURL != home.standardizedFileURL else { return false }
        try? fm.removeItem(at: home)
        do { try fm.moveItem(at: staging, to: home) } catch { return false }
        guard let b = BundleStore.load(root: home), b.version == version else {
            try? fm.removeItem(at: home)
            return false
        }
        known[version] = b
        adopt(version)
        return true
    }

    private func adopt(_ version: String) {
        state.adopt(version, active: active?.version)
        save()
        prune(keepPartial: nil)
    }

    // MARK: - Files

    private static let partial = ".partial-"
    private var stateFile: URL { dir.appendingPathComponent(".state.json") }

    private func save() {
        guard !testing, shipped != nil, let d = state.encoded() else { return }
        try? d.write(to: stateFile, options: .atomic)
    }

    /// Deletes downloaded versions that are neither the newest, the one before, nor the one running now, and
    /// half-built folders other than the one named.
    private func prune(keepPartial: String?) {
        let fm = FileManager.default
        let keep = state.keep(active: active?.version)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name != stateFile.lastPathComponent {
            if name.hasPrefix(BundleStore.partial) ? name != keepPartial : !keep.contains(name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// A folder as a bundle, if its manifest reads and every file is there at its size. (Each file's hash was
    /// checked when it was written; the size check catches a folder that was cut short.)
    nonisolated static func load(root: URL) -> ReadyBundle? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let m = BundleManifest.parse(data) else { return nil }
        let b = ReadyBundle(manifest: m, root: root)
        let fm = FileManager.default
        for f in m.files {
            guard let size = (try? fm.attributesOfItem(atPath: b.url(of: f).path))?[.size] as? NSNumber, size.intValue == f.bytes else { return nil }
        }
        return b
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True if the file is there and is exactly what the manifest says (size and SHA-256).
    private nonisolated static func matches(_ url: URL, _ f: BundleFile) -> Bool {
        guard let d = try? Data(contentsOf: url), d.count == f.bytes else { return false }
        return sha256(d) == f.sha256
    }

    /// Builds the version in its staging folder: a file already there from a try before is kept if it checks out;
    /// one whose contents are on the phone under another version is copied; the rest are downloaded. Every file's
    /// SHA-256 is checked before it's kept, and the manifest goes in last.
    private nonisolated static func stage(_ manifest: BundleManifest, raw: Data, have: [String: URL], into staging: URL, session: URLSession) async -> Bool {
        let fm = FileManager.default
        var have = have
        for f in manifest.files {
            let dest = staging.appendingPathComponent("files" + f.path)
            if matches(dest, f) { have[f.sha256] = dest; continue }
            try? fm.removeItem(at: dest)
            do { try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { return false }
            if let src = have[f.sha256] {
                try? fm.copyItem(at: src, to: dest)
                if matches(dest, f) { continue }
                try? fm.removeItem(at: dest)
            }
            guard let url = manifest.source(of: f), let data = await fetch(url, session),
                  data.count == f.bytes, sha256(data) == f.sha256 else { return false }
            do { try data.write(to: dest, options: .atomic) } catch { return false }
            have[f.sha256] = dest
        }
        do { try raw.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic) } catch { return false }
        return true
    }

    // MARK: - The network: https, train.time2play.live only, no cookies, nothing kept

    private nonisolated static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c, delegate: SameSiteOnly(), delegateQueue: nil)
    }

    private nonisolated static func fetch(_ url: URL, _ session: URLSession) async -> Data? {
        guard BundleManifest.allowed(url) else { return nil }
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: req), let http = response as? HTTPURLResponse,
              http.statusCode == 200, BundleManifest.allowed(http.url) else { return nil }
        return data
    }
}

/// Whether a bundle is being served, for the bridge's handlers (which check where a message came from): the same
/// as `BundleStore.shared.bundled`, readable from anywhere.
enum BundleMode {
    static var on = false
}

/// A redirect is followed only to https on train.time2play.live.
private final class SameSiteOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(BundleManifest.allowed(request.url) ? request : nil)
    }
}

#if DEBUG
/// The UI tests' bundle (`-uitest-bundle`): three files and a manifest, written to a temporary folder by the test
/// build itself, so bundled mode is tested with no network. The front page is the test's own stand-in page
/// (VIRT_TEST_HTML), which talks like Training.
enum BundleFixture {
    static let version = "fixture-1"

    static func make(html: String?) -> ReadyBundle? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("virt-fixture-bundle")
        try? fm.removeItem(at: root)
        let files: [(String, String)] = [
            ("/pages/index.html", html ?? "<!doctype html><html><body><p>fixture</p></body></html>"),
            ("/pages/privacy.html", "<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head>"
                + "<body style=\"font: 17px -apple-system; padding: 20px\"><h1>Privacy</h1><p>privacy: from the bundle</p>"
                + "<p><a href=\"https://example.com/\" style=\"font-size: 20px\">Outside</a></p></body></html>"),
            ("/_train/immutable/app.js", "document.getElementById('script').textContent = 'script: loaded';\n"),
        ]
        var list: [[String: Any]] = []
        for (path, text) in files {
            let data = Data(text.utf8)
            let url = root.appendingPathComponent("files" + path)
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            } catch { return nil }
            list.append(["path": path, "sha256": BundleStore.sha256(data), "bytes": data.count])
        }
        let manifest: [String: Any] = [
            "v": 1, "version": version, "minApp": 1, "latestApp": 1, "store": "",
            "entries": ["/": "/pages/index.html", "/try": "/pages/index.html", "/privacy": "/pages/privacy.html"],
            "files": list,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest),
              (try? data.write(to: root.appendingPathComponent("manifest.json"))) != nil else { return nil }
        return BundleStore.load(root: root)
    }
}
#endif
