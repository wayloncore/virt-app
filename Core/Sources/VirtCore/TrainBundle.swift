import Foundation

/// Training's screens shipped inside the app (wayloncore/tyleralocke#822). The website's build lists every file its
/// four pages can ask for in a manifest (`https://train.time2play.live/app/manifest.json`); Virt keeps a copy of those
/// files (one embedded when the app is built, newer ones downloaded quietly) and serves them itself at
/// `virt-app://train/`, so Training opens at once and with no signal. Everything here is plain values, so it tests on
/// Linux; the app's `BundleStore` does the files and the network.

/// One file of the bundle, as the manifest lists it.
public struct BundleFile: Equatable, Sendable {
    /// The path the page asks for ("/_train/immutable/entry/start.abc.js"), also where it's kept under the version's folder.
    public let path: String
    /// The file's SHA-256, 64 lowercase hex characters.
    public let sha256: String
    public let bytes: Int

    public init(path: String, sha256: String, bytes: Int) {
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
    }
}

/// Which paths a manifest may name. A path is used as a file name under the version's folder, so it's refused unless
/// it's plainly inside it.
public enum BundlePath {
    /// A file's path: starts with "/", names something (not a folder), and has no "..", no scheme or second "//", no
    /// query or fragment, no backslash and no control characters.
    public static func safe(_ p: String) -> Bool {
        guard p.hasPrefix("/"), p.count >= 2, p.utf8.count <= 512, !p.hasSuffix("/") else { return false }
        if p.contains("..") || p.contains("//") || p.contains("?") || p.contains("#") || p.contains("\\") { return false }
        return !p.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A page's address ("/", "/try"): "/" itself, or a safe path.
    public static func safePage(_ p: String) -> Bool { p == "/" || safe(p) }

    /// A version's name is a folder name: letters, digits, ".", "_" and "-", not starting with a dot, 64 at most.
    public static func safeVersion(_ v: String) -> Bool {
        guard (1...64).contains(v.count), !v.hasPrefix(".") else { return false }
        return v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// True for a path whose last part has an extension ("/x/app.js"): a file, not one of the page's own routes.
    public static func looksLikeFile(_ p: String) -> Bool {
        let last = p.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return last.contains(".")
    }
}

/// The Content-Type each kind of file is served with.
public enum BundleContent {
    public static let html = "text/html; charset=utf-8"
    public static let fallback = "application/octet-stream"

    static let types: [String: String] = [
        "html": html, "htm": html,
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8", "map": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "txt": "text/plain; charset=utf-8", "xml": "application/xml; charset=utf-8",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
        "avif": "image/avif", "gif": "image/gif", "ico": "image/x-icon",
        "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "ogg": "audio/ogg",
        "mp4": "video/mp4", "webm": "video/webm", "wasm": "application/wasm", "pdf": "application/pdf",
    ]

    public static func type(forPath path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return fallback }
        return types[last[last.index(after: dot)...].lowercased()] ?? fallback
    }
}

/// What the scheme handler answers for one request.
public enum BundleAnswer: Equatable, Sendable {
    case file(BundleFile, type: String)
    case notFound
}

/// The manifest: which version this is, which app builds can run it, the pages and every file.
public struct BundleManifest: Equatable, Sendable {
    /// The website's build id.
    public let version: String
    /// The lowest app build that can run this bundle.
    public let minApp: Int
    /// The newest app build on the Store (the page's "Update Virt" card reads it; Virt only carries it).
    public let latestApp: Int
    public let store: String
    /// Where the files are fetched from, as a path in front of each file's own ("" for the site's own paths, or
    /// "/app/files").
    public let base: String
    /// The pages: the address the page is at ("/", "/try") and the file that is its HTML.
    public let entries: [String: String]
    public let files: [BundleFile]
    private let byPath: [String: BundleFile]

    public static let host = "train.time2play.live"
    public static let url = URL(string: "https://\(host)/app/manifest.json")!
    /// The only manifest format this build reads.
    public static let format = 1

    /// Reads a manifest. Fields it doesn't know are ignored; one that's wrong in any way that matters (another
    /// format, a version that can't be a folder name, an unsafe path, a hash that isn't one, a page with no file, no
    /// "/" page) is no manifest at all, so a half-good one is never used.
    public static func parse(_ data: Data) -> BundleManifest? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard int(j["v"]) == format, let version = j["version"] as? String, BundlePath.safeVersion(version) else { return nil }
        guard let base = base(j["base"]) else { return nil }
        guard let list = j["files"] as? [Any], !list.isEmpty, list.count <= 5000 else { return nil }
        var files: [BundleFile] = []
        var byPath: [String: BundleFile] = [:]
        for item in list {
            guard let o = item as? [String: Any], let path = o["path"] as? String, BundlePath.safe(path),
                  let sha = o["sha256"] as? String, shaOk(sha), let bytes = int(o["bytes"]), bytes >= 0 else { return nil }
            let f = BundleFile(path: path, sha256: sha.lowercased(), bytes: bytes)
            if let had = byPath[path] {
                if had != f { return nil }  // the same path twice with different contents
                continue
            }
            byPath[path] = f
            files.append(f)
        }
        guard let pages = j["entries"] as? [String: Any], !pages.isEmpty else { return nil }
        var entries: [String: String] = [:]
        for (page, file) in pages {
            guard BundlePath.safePage(page), let file = file as? String, byPath[file] != nil else { return nil }
            entries[page] = file
        }
        guard entries["/"] != nil else { return nil }
        return BundleManifest(version: version, minApp: int(j["minApp"]) ?? 0, latestApp: int(j["latestApp"]) ?? 0,
                              store: j["store"] as? String ?? "", base: base, entries: entries, files: files, byPath: byPath)
    }

    /// A whole number, however JSON gave it (never a fraction).
    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double, d == d.rounded(), abs(d) < 1e15 { return Int(d) }
        return nil
    }

    private static func shaOk(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// `base` as a path prefix: none, "/app/files", or the same written with the site's own address. Anything else
    /// (another host, another scheme) makes the manifest unusable: Virt only ever talks to train.time2play.live.
    private static func base(_ v: Any?) -> String? {
        if v == nil || v is NSNull { return "" }
        guard var s = v as? String else { return nil }
        let site = "https://\(host)"
        if s.hasPrefix(site) { s = String(s.dropFirst(site.count)) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return "" }
        return BundlePath.safe(s) ? s : nil
    }

    public func file(_ path: String) -> BundleFile? { byPath[path] }

    /// A page's address without a trailing slash ("/try/" is "/try"; "" is "/").
    private static func page(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    /// True for one of the bundle's own pages ("/", "/try", "/privacy", "/terms").
    public func isPage(_ path: String) -> Bool { entries[Self.page(path)] != nil }

    /// What to serve for a request's path: the file itself, a page's HTML, a 404 for a file that isn't in the
    /// manifest, and the front page for any other address (the page's own router takes it from there).
    public func answer(path: String) -> BundleAnswer {
        if path.contains("..") { return .notFound }
        if let f = byPath[path] { return .file(f, type: BundleContent.type(forPath: f.path)) }
        let p = Self.page(path)
        if let e = entries[p], let f = byPath[e] { return .file(f, type: BundleContent.html) }
        if BundlePath.looksLikeFile(p) { return .notFound }
        if let e = entries["/"], let f = byPath[e] { return .file(f, type: BundleContent.html) }
        return .notFound
    }

    /// Where a file is downloaded from: always https on train.time2play.live.
    public func source(of file: BundleFile) -> URL? {
        guard let p = (base + file.path).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        guard let u = URL(string: "https://\(Self.host)\(p)"), Self.allowed(u) else { return nil }
        return u
    }

    /// The only place the updater may fetch from (a redirect anywhere else is refused).
    public static func allowed(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == host && (url?.port == nil || url?.port == 443)
    }
}

/// What Virt remembers about its bundles between launches (a small JSON file beside the downloaded versions).
/// Saved-data rule: fields are only ever added, each optional.
public struct BundleState: Codable, Equatable, Sendable {
    /// The newest version that's ready: the one the next launch uses.
    public var current: String?
    /// The one before it, kept to go back to.
    public var previous: String?
    /// Versions that didn't start (no bridge message in time): never tried again by this build.
    public var failed: [String]?
    /// Versions whose page has spoken on the bridge at least once: they're no longer watched at launch.
    public var proven: [String]?
    /// When the manifest was last asked for, in epoch seconds.
    public var lastCheck: Double?
    /// The app build that wrote this. A different build starts from its own shipped copy again.
    public var build: Int?

    public init(current: String? = nil, previous: String? = nil, failed: [String]? = nil, proven: [String]? = nil,
                lastCheck: Double? = nil, build: Int? = nil) {
        self.current = current
        self.previous = previous
        self.failed = failed
        self.proven = proven
        self.lastCheck = lastCheck
        self.build = build
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ d: Data) -> BundleState? { try? JSONDecoder().decode(BundleState.self, from: d) }

    public func hasFailed(_ v: String) -> Bool { failed?.contains(v) ?? false }
    public func isProven(_ v: String) -> Bool { proven?.contains(v) ?? false }

    /// The state as this build should read it. A new app build starts over from the copy it shipped with (its
    /// screens were made for it) and forgets which versions failed, since the app itself has changed; it checks for
    /// something newer straight away.
    public func forBuild(_ b: Int) -> BundleState {
        if build == b { return self }
        return BundleState(build: b)
    }

    /// The versions to try at launch, in order: the newest ready one, the one before it, then the shipped copy. A
    /// version that failed, or whose files aren't all there (`usable`), is left out. Empty means no bundle: Virt
    /// loads the website as it always has.
    public func launchOrder(shipped: String?, usable: Set<String>) -> [String] {
        var out: [String] = []
        for v in [current, previous, shipped] {
            guard let v, !hasFailed(v), usable.contains(v), !out.contains(v) else { continue }
            out.append(v)
        }
        return out
    }

    /// A version didn't start: it's never tried again.
    public mutating func fail(_ v: String) {
        if !hasFailed(v) { failed = (failed ?? []) + [v] }
        if current == v { current = previous; previous = nil }
        if previous == v { previous = nil }
    }

    /// A version's page spoke on the bridge: it works.
    public mutating func prove(_ v: String) {
        if !isProven(v) { proven = Array(((proven ?? []) + [v]).suffix(8)) }
    }

    /// A newer version is ready: the next launch uses it. The one running now (`active`, known to work) is kept as
    /// the one to go back to; with none running, the one that was newest.
    public mutating func adopt(_ v: String, active: String?) {
        guard current != v else { return }
        let keep = active ?? current
        previous = keep == v ? previous : keep
        current = v
    }

    /// The downloaded versions worth keeping: the newest, the one before, and the one running now. The rest go.
    public func keep(active: String?) -> Set<String> {
        Set([current, previous, active].compactMap { $0 })
    }
}

/// What a freshly fetched manifest means for this phone.
public enum BundleUpdate: Equatable, Sendable {
    /// Already have it (or it failed before): nothing to do.
    case nothing
    /// It needs a newer app than this one: keep running the newest bundle this build can.
    case tooOld
    /// Fetch these files (the ones whose contents aren't on the phone yet; maybe none), then the version is ready.
    case download([BundleFile])

    /// - `usable`: the versions whose files are all on the phone (the shipped one included).
    /// - `have`: the hashes of every file already on the phone, in any version.
    public static func decide(state: BundleState, shipped: String?, usable: Set<String>, build: Int,
                              manifest: BundleManifest, have: Set<String>) -> BundleUpdate {
        let v = manifest.version
        if state.hasFailed(v) { return .nothing }
        if manifest.minApp > build { return .tooOld }
        if usable.contains(v) {
            if state.current == v { return .nothing }
            if state.current == nil, shipped == v { return .nothing }
            return .download([])  // already here (the site went back to an earlier version): just make it the newest
        }
        var seen = have
        var need: [BundleFile] = []
        for f in manifest.files where !seen.contains(f.sha256) {
            seen.insert(f.sha256)
            need.append(f)
        }
        return .download(need)
    }
}

/// When to ask the website for a newer manifest: on launch and when the app comes forward, but at most every 30
/// minutes and never during a workout.
public enum BundleCheck {
    public static let every: Double = 30 * 60
    /// How long a new version has to post its first bridge message before Virt goes back to the one before.
    public static let startSeconds: Double = 8
    /// How long the old page gets, once, to send what it had saved on the phone (the move from the old way).
    public static let moveSeconds: Double = 10

    /// `now` and `last` are epoch seconds. A clock that went backward counts as due.
    public static func due(now: Double, last: Double?, midWorkout: Bool) -> Bool {
        if midWorkout { return false }
        guard let last else { return true }
        return now - last >= every || now < last
    }
}

/// The part of a file a request asked for (`Range: bytes=0-99`), for sounds and video; nil for the whole file or a
/// range that makes no sense.
public enum ByteRange {
    public static func parse(_ header: String?, size: Int) -> ClosedRange<Int>? {
        guard let h = header?.trimmingCharacters(in: .whitespaces).lowercased(), h.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = h.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let a = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let b = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if a.isEmpty {  // the last n bytes
            guard let n = Int(b), n > 0 else { return nil }
            return max(0, size - n)...(size - 1)
        }
        guard let start = Int(a), start >= 0, start < size else { return nil }
        if b.isEmpty { return start...(size - 1) }
        guard let end = Int(b), end >= start else { return nil }
        return start...min(end, size - 1)
    }
}

/// The scripts Virt runs before the page's own.
public enum PageStart {
    /// Tells Training it's in Virt: Virt plays the lead-in, zero, set and finish sounds itself, has its own settings
    /// sheet, which app build this is (for the page's "Update Virt" card), and `bundled: true` when the page was
    /// served from inside the app. Also asks WebKit to mix the page's own sounds with his music.
    /// `prefs`: Virt's settings for the You tab (`AppPrefs`), as `kineticApp.prefs`. That object itself isn't frozen:
    /// each `kinetic:prefs` event brings it up to date in place. Without it, the script is exactly as before.
    public static func script(build: Int, prefs: AppPrefs? = nil) -> String {
        let prefsLine = prefs.map { "\n    app.prefs = \($0.json);" } ?? ""
        return """
        (() => {
          try {
            const app = { app: 'virt', version: 2, sounds: ['lead-in', 'zero', 'set', 'finish'], settings: true, build: \(build) };
            if (location.protocol === '\(Navigation.bundleScheme):') app.bundled = true;\(prefsLine)
            window.kineticApp = Object.freeze(app);
          } catch (e) {}
          try { if (navigator.audioSession && navigator.audioSession.type === 'auto') navigator.audioSession.type = 'ambient'; } catch (e) {}
        })();
        """
    }

    /// Bundled mode only: tells the page where its API is (the website's own hook, besides the scheme). Only on the
    /// bundled page.
    public static let apiBaseScript = """
        (() => { try { if (\(Navigation.bundledCheck)) window.T2P_API_BASE = 'https://\(Navigation.friendHost)'; } catch (e) {} })();
        """
}

/// Moving from the old way (tyleralocke#822). A phone that used a build before bundles may have a workout saved on
/// the phone and not yet sent, in train.time2play.live's own storage, which the bundled page (another origin) can't
/// see. So the first launch in bundled mode with a signal loads the old page once, hidden, with the session handed
/// over, and gives it up to 10 seconds to send what's waiting; then Virt is on the bundle for good.
public enum BundleMove {
    /// UserDefaults: the move is done (or there was nothing to move). A new key.
    public static let doneKey = "virt.bundle-moved"
    /// UserDefaults: how many times the old page was given its 10 seconds and still had something waiting. A new key.
    public static let triesKey = "virt.bundle-move-tries"
    /// After this many tries with something still waiting, Virt stops trying (it would never send).
    public static let maxTries = 3

    public enum Step: Equatable, Sendable {
        /// Nothing to do: open Training from the bundle.
        case go
        /// Nothing to move (no one was signed in): note it's done, and go.
        case doneAndGo
        /// Load the old page, hidden, first.
        case run
        /// No signal: go on from the bundle now, and try the hidden load on a later launch.
        case later
    }

    public static func step(done: Bool, hasSession: Bool, online: Bool) -> Step {
        if done { return .go }
        if !hasSession { return .doneAndGo }
        return online ? .run : .later
    }

    /// After the hidden load: whether the move is done, and the tries so far. A page that never loaded (the signal
    /// dropped) doesn't count as a try. One that loaded with nothing left waiting is done; one that still has
    /// something waiting gets another go on a later launch, `maxTries` in all.
    public static func after(loaded: Bool, waiting: Bool, tries: Int) -> (done: Bool, tries: Int) {
        guard loaded else { return (false, tries) }
        if !waiting { return (true, tries) }
        return (tries + 1 >= maxTries, tries + 1)
    }

    /// Run on the old page: true while a finished workout is still waiting to be sent (Training's offline queue;
    /// the key is the website's src/lib/health/client-local.js). If it can't tell, it says true, so the page gets
    /// its full time.
    public static let waitingScript = """
        (() => { try { const q = JSON.parse(localStorage.getItem('studio.gym.queue') || '[]');
          return Array.isArray(q) && q.length > 0; } catch (e) { return true; } })()
        """
}
