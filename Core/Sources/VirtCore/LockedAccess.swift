import Foundation

/// What a lock-screen press may read with the phone locked (docs/lock-screen-buttons.md).
///
/// A Live Activity's buttons run in Virt's process while the phone is locked. Anything they read has to be readable
/// then: after the phone's first unlock since it was turned on, not only while it's unlocked.
///
/// - Keychain items: the `kSecAttrAccessible` class, as the Keychain stores it (its `pdmn` attribute). "When unlocked"
///   (`ak`, `aku`, `akpu`) can't be read while locked; "after first unlock" (`ck`, `cku`) and "always" (`dk`, `dku`)
///   can. Apple: the default for a new item is "when unlocked", so every item Virt writes says its class outright.
/// - Files (UserDefaults' own file included): the data protection class. "Complete" can't be read while locked;
///   "complete until first user authentication" (iOS's default for an app's files) and "none" can. "Complete unless
///   open" can't open an existing file while locked, so it counts as not readable.
public enum LockedAccess {
    /// The class Virt's keychain items use: after the first unlock, this phone only
    /// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
    public static let keychainClass = "cku"

    /// Keychain classes a locked phone can read (after its first unlock).
    public static let keychainReadableWhileLocked: Set<String> = ["ck", "cku", "dk", "dku"]

    /// A keychain item saved with this class has to be moved to `keychainClass` (nil: no item, nothing to move).
    public static func keychainNeedsMove(_ stored: String?) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        return !keychainReadableWhileLocked.contains(stored)
    }

    /// File protection classes (FileProtectionType's raw values) a locked phone can read after its first unlock.
    public static let fileReadableWhileLocked: Set<String> = [
        "NSFileProtectionCompleteUntilFirstUserAuthentication",
        "NSFileProtectionNone",
    ]

    /// Whether a file with this protection can be read with the phone locked. nil: no class set on the file (the
    /// simulator, or a phone with no passcode), which reads at any time.
    public static func fileReadable(_ protection: String?) -> Bool {
        guard let protection, !protection.isEmpty else { return true }
        return fileReadableWhileLocked.contains(protection)
    }

    /// The test build's one-word answer for the status line: "ok", or what can't be read while locked.
    /// `keychain` is each item's name and its stored class (nil: no item, or no keychain in an unsigned build).
    public static func summary(keychain: [(name: String, stored: String?)], files: [(name: String, protection: String?)]) -> String {
        var problems: [String] = []
        for k in keychain where keychainNeedsMove(k.stored) { problems.append("\(k.name)=\(k.stored ?? "")") }
        for f in files where !fileReadable(f.protection) { problems.append("\(f.name)=\(f.protection ?? "")") }
        return problems.isEmpty ? "ok" : problems.joined(separator: ",")
    }
}

/// Log set presses the page hasn't been handed yet (#573, docs/lock-screen-buttons.md).
///
/// A press from the lock screen can come when there's no page to hand it to: iOS started Virt in the background just
/// for the press (no screen, no web view), or Training was still loading. The board has already moved on (its rest
/// started), so the page must still hear about the set when it's up, or the set would never be saved. Each press keeps
/// the moment it was pressed and its own id, so the page logs it from then and drops one it has already seen.
///
/// Kept on the phone in UserDefaults under `key` (a new key) as JSON, so a press survives iOS ending Virt before the
/// page woke. Presses older than `keepFor` are dropped (the workout is long over).
public struct PendingLogs: Codable, Equatable, Sendable {
    public static let key = "virt.pending.logs"
    /// As long as the page's word that a workout is live holds (LiveWorkout.trustLimit).
    public static let keepFor: TimeInterval = LiveWorkout.trustLimit
    /// More than this waiting means something's wrong; the oldest go first.
    public static let limit = 40

    public struct Press: Codable, Equatable, Sendable {
        public var at: Date
        public var id: String
        public init(at: Date, id: String) { self.at = at; self.id = id }
    }

    public private(set) var presses: [Press] = []

    public init() {}

    public var count: Int { presses.count }
    public var isEmpty: Bool { presses.isEmpty }

    /// Holds a press for the page. The same id twice is kept once.
    public mutating func add(at: Date, id: String) {
        guard !presses.contains(where: { $0.id == id }) else { return }
        presses.append(Press(at: at, id: id))
        presses.sort { $0.at < $1.at }
        if presses.count > Self.limit { presses.removeFirst(presses.count - Self.limit) }
    }

    /// Holds a `log` command for the page (any other command isn't held: a late −15 or skip would land on the wrong
    /// timer).
    public mutating func hold(_ command: PageCommand) {
        guard case .log(let at, let id) = command else { return }
        add(at: at, id: id ?? "held-\(Int((at.timeIntervalSince1970 * 1000).rounded()))")
    }

    /// Everything to hand the page now, oldest first, and nothing held after. Too old (or from the future: a clock
    /// that moved) is dropped.
    public mutating func take(now: Date) -> [PageCommand] {
        let out = presses.filter { p in
            let age = now.timeIntervalSince(p.at)
            return age >= -60 && age < Self.keepFor
        }.map { PageCommand.log(at: $0.at, id: $0.id) }
        presses = []
        return out
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> PendingLogs? { data.flatMap { try? JSONDecoder().decode(PendingLogs.self, from: $0) } }
}
