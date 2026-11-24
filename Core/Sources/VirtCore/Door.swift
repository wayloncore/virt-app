import Foundation

/// Which way into Training this phone uses (#578, part 2). Chosen once on the first screen and remembered; Virt's
/// settings can switch it.
///
/// - `tyler`: Tyler's own. Cloudflare Access's sign-in, then studio Training. Exactly as before friends existed.
/// - `friend`: Training for friends. Sign in with Apple (a Time2Play account), then train.time2play.live, the same
///   Training screens on the friend's own data with Tyler's private parts left out.
///
/// Saved-data rule: the saved value is the raw string under `Door.key` (a new key; nothing older is renamed).
public enum Door: String, Codable, Sendable, CaseIterable {
    case tyler, friend

    /// Where the choice is kept (UserDefaults).
    public static let key = "virt.door"

    /// What's saved after someone signs out of a door: the first screen asks again on the next launch.
    public static let none = "none"

    /// The door to open at launch. A saved choice wins, and a saved `none` (signed out of a door) asks again. With
    /// nothing saved, a phone that already used Virt before doors existed (Tyler's: a studio sign-in, a saved `today`,
    /// his reminder or sound settings) keeps going straight to the studio, as it always has. A new phone has no door
    /// yet: the first screen asks.
    public static func resolve(saved: String?, usedBefore: Bool) -> Door? {
        if let s = saved { return Door(rawValue: s) }
        return usedBefore ? .tyler : nil
    }

    /// Whether this phone has been shown Sign in with Apple in place of the studio's sign-in (UserDefaults; a new key).
    public static let appleAskedKey = "virt.apple-asked"
    /// Set once Tyler's own Apple ID has opened his Training on this phone (an owner session). From then on the
    /// first screen never offers the studio's sign-in, and a sign-in that can't reach his Training says so
    /// instead of opening a friend's account. A new key.
    public static let ownerOpenedKey = "virt.owner-apple"

    /// What a first-screen sign-in does with the owner path's answer.
    public enum OwnerStep: Equatable, Sendable { case open, link, sayUnreachable, goOnAsFriend }

    /// Tyler's phone (it used the studio, or his Apple ID opened his Training before) never falls through to a
    /// friend's account by accident: not linked asks him to link, and no answer says so. Anyone else goes on to
    /// their own account.
    public static func ownerStep(owner: Bool, notLinked: Bool, studioUsed: Bool, ownerOpened: Bool) -> OwnerStep {
        if owner { return .open }
        if notLinked { return studioUsed || ownerOpened ? .link : .goOnAsFriend }
        return ownerOpened ? .sayUnreachable : .goOnAsFriend
    }

    /// The door at launch. Everyone signs in with Apple, Tyler included (Nov 23: the studio's Cloudflare sign-in is
    /// gone from Virt altogether). A phone still set to it gets the first screen, every time, until Apple has signed
    /// it in. Only the test build still opens the studio's door (`studioAllowed`: its stand-in pages run there, and
    /// there it is offered Apple once, as before).
    public static func atLaunch(saved: String?, usedBefore: Bool, appleAsked: Bool, studioAllowed: Bool = false) -> Door? {
        let d = resolve(saved: saved, usedBefore: usedBefore)
        return d == .tyler && (!studioAllowed || !appleAsked) ? nil : d
    }

    /// Where Training starts for this door.
    public var home: URL {
        switch self {
        case .tyler: return Navigation.home
        case .friend: return Navigation.friendHome
        }
    }
}

/// A friend's Time2Play session: what `POST /live/players/apple` answers (the website's src/lib/server/accounts/api.js).
/// Kept in this phone's Keychain by the app. Saved-data rule: fields are only ever added (new ones optional).
public struct FriendSession: Codable, Equatable, Sendable {
    public var token: String
    /// The account's name, for Virt's settings ("Signed in as Sam").
    public var name: String
    /// When the server's session ends, in epoch milliseconds (the server's own clock), if it said.
    public var expires: Double?
    /// Tyler's own Training (#732): an owner session from `POST /live/train/owner/apple`, for the studio's Training on
    /// train.time2play.live. Checked and signed out on that host, never deleted from the phone. Added field (optional).
    public var owner: Bool?

    public init(token: String, name: String, expires: Double? = nil, owner: Bool? = nil) {
        self.token = token
        self.name = name
        self.expires = expires
        self.owner = owner
    }

    /// An owner session (Tyler's own Training).
    public var isOwner: Bool { owner == true }

    /// A token as the website takes it: letters and digits only, 16 to 200 of them (client.js `tokenOk`). That's also
    /// what makes it safe to write into the hand-over script.
    public static func tokenOk(_ t: String) -> Bool {
        (16...200).contains(t.count) && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Still worth handing to the page: a good token that hasn't run out.
    public func usable(now: Date) -> Bool {
        guard Self.tokenOk(token) else { return false }
        guard let e = expires else { return true }
        return e > now.timeIntervalSince1970 * 1000
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ d: Data) -> FriendSession? { try? JSONDecoder().decode(FriendSession.self, from: d) }
}

/// The friend sign-in's talk with the website, as plain values: the requests' bodies and what the answers mean. The
/// app sends them (URLSession); the tests check them here. The accounts paths are on tyleralocke.com only
/// (time2play-app's Accounts.swift does the same); train.time2play.live answers only its own /live/train/.
public enum FriendSignIn {
    public static let api = URL(string: "https://tyleralocke.com/live/players/")!
    public static func url(_ path: String) -> URL { api.appendingPathComponent(path) }
    /// The face a new account gets (Time2Play's own default); a friend can change it in the Time2Play app.
    public static let face = 9

    /// `POST /live/players/apple`: Apple's identity token, checked by the server. A new account needs `over13: true`
    /// and a name; an existing one ignores both.
    public static func appleBody(identityToken: String, name: String, over13: Bool, app: String) -> Data {
        let o: [String: Any] = ["identityToken": identityToken, "name": name, "face": face, "over13": over13, "app": app]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    /// `POST /live/players/delete`: a fresh Apple authorization code lets the server revoke Sign in with Apple.
    public static func deleteBody(authorizationCode: String?) -> Data {
        let o: [String: Any] = authorizationCode.map { ["authorizationCode": $0] } ?? [:]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    public enum Outcome: Equatable, Sendable {
        case signedIn(FriendSession)
        /// A new account needs a name (code `name`).
        case needsName
        /// Accounts are for 13 and up (code `age`).
        case tooYoung
        /// The session's gone or ran out (code `session`, or a 401).
        case signedOut
        /// Anything else, in the server's own words when it gave some.
        case failed(String)
    }

    /// What an answer from the accounts paths means. `status` 0 is no answer at all.
    public static func outcome(status: Int, body: Data) -> Outcome {
        let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let code = j["code"] as? String
        let error = j["error"] as? String
        if (200..<300).contains(status) {
            let account = j["account"] as? [String: Any]
            if let t = j["token"] as? String, tokenOk(t) {
                let e = j["expires"]
                let expires = (e as? Double) ?? (e as? Int).map(Double.init) ?? (e as? NSNumber)?.doubleValue
                return .signedIn(FriendSession(token: t, name: account?["name"] as? String ?? "", expires: expires))
            }
            return .failed("Couldn't sign in. Try again.")
        }
        switch code {
        case "name": return .needsName
        case "age": return .tooYoung
        case "session": return .signedOut
        default: break
        }
        if status == 401, code == nil { return .signedOut }
        if status == 0 { return .failed("No connection. Check your signal and try again.") }
        return .failed(error ?? "Something went wrong (\(status)). Try again.")
    }

    /// `GET /live/players/me` at launch: true if the session is good, false if the server says it's gone (a 401), nil
    /// when it can't tell (no signal, a server problem). Only a false signs the friend out.
    public static func stillSignedIn(status: Int, body: Data) -> Bool? {
        if (200..<300).contains(status) { return true }
        if status == 401 { return false }
        return nil
    }

    private static func tokenOk(_ t: String) -> Bool { FriendSession.tokenOk(t) }

    /// Runs at the start of each train.time2play.live page: hands the page the session the way its client.js reads it
    /// (`window.T2P_SESSION`, never in the address). The page swaps it once for its own cookie and deletes it. Only on
    /// that host, so no other page ever sees it; nil for a token that isn't letters and digits.
    public static func handoverScript(token: String) -> String? {
        guard tokenOk(token) else { return nil }
        return """
            (() => { try { if (location.protocol === 'https:' && location.hostname === '\(Navigation.friendHost)') \
            window.T2P_SESSION = '\(token)'; } catch (e) {} })();
            """
    }

    /// Runs on train.time2play.live pages: tells Virt when the friend taps the page's own "Sign out here", so Virt
    /// signs out too (and doesn't hand the page its session again on the next load). Posts to Virt's own `virtAccount`
    /// handler, not the page's `kinetic` bridge.
    public static let signOutWatchScript = """
        (() => { try { if (location.hostname !== '\(Navigation.friendHost)') return;
          document.addEventListener('click', (e) => {
            const t = e.target && e.target.closest ? e.target.closest('[data-sign-out]') : null;
            if (t && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.virtAccount)
              window.webkit.messageHandlers.virtAccount.postMessage({ type: 'signedOut' });
          }, true); } catch (e) {} })();
        """

    /// What a friend types as their name: trimmed, 2 to 24 characters.
    public static func cleanName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 2 ? String(t.prefix(24)) : nil
    }
}

/// Tyler's own Training with Sign in with Apple (#730, #732; the website's src/lib/server/training-friends/owner.js).
/// Everyone signs in with Apple. Virt asks the owner path first: Tyler's linked Apple ID gets an owner session for his
/// studio Training; anyone else gets "not linked" and goes on to their own Time2Play account (FriendSignIn). The server
/// decides whose data it is; the page never picks.
public enum OwnerSignIn {
    public static let base = URL(string: "https://\(Navigation.friendHost)/live/train/")!
    public static func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    /// `POST /live/train/owner/apple`: the same identity token as the friend's sign-in.
    public static func appleBody(identityToken: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["identityToken": identityToken], options: [.sortedKeys])) ?? Data()
    }

    public enum Outcome: Equatable, Sendable {
        /// Tyler's linked Apple ID: his session.
        case owner(FriendSession)
        /// Not linked (a friend, or Tyler before linking): the four-character code the studio links with.
        case notLinked(code: String)
        /// The owner path isn't there (its switch is off) or couldn't answer: go on as a friend.
        case unavailable
    }

    public static func outcome(status: Int, body: Data) -> Outcome {
        let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if (200..<300).contains(status), let t = j["token"] as? String, FriendSession.tokenOk(t) {
            let e = j["expires"]
            let expires = (e as? Double) ?? (e as? Int).map(Double.init) ?? (e as? NSNumber)?.doubleValue
            return .owner(FriendSession(token: t, name: "Tyler", expires: expires, owner: true))
        }
        if status == 403, j["code"] as? String == "not-linked", let c = j["link"] as? String, codeOk(c) {
            return .notLinked(code: c)
        }
        return .unavailable
    }

    /// A link code as the studio takes it: four capital letters or digits (also what makes it safe in a script).
    public static func codeOk(_ c: String) -> Bool {
        c.count == 4 && c.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// Run on Tyler's studio Training page (behind Cloudflare Access, so only he reaches it) with WKWebView's
    /// callAsyncJavaScript and `code` as its argument: links the Apple sign-in that got that code. Answers
    /// `{ ok, error }`. Only on studio.tyleralocke.com.
    public static let linkScript = """
        if (location.hostname !== 'studio.tyleralocke.com') return { ok: false, error: 'Open the studio first.' };
        try {
          const r = await fetch('/api/training-owner', { method: 'POST', credentials: 'same-origin',
            headers: { 'content-type': 'application/json' }, body: JSON.stringify({ do: 'link', code }) });
          const j = await r.json().catch(() => ({}));
          return { ok: r.ok && !!j.ok, error: String(j.error || '') };
        } catch (e) { return { ok: false, error: 'No connection.' }; }
        """

    /// Run on the studio page before moving Tyler to his Apple sign-in: true when a workout still waits on this
    /// phone (Training's offline queue, or a draft with sets in it), so nothing he hasn't sent is left behind on the
    /// studio's host. The keys are the website's src/lib/health/client-local.js.
    public static let waitingScript = """
        try {
          const q = JSON.parse(localStorage.getItem('studio.gym.queue') || '[]');
          if (Array.isArray(q) && q.length) return true;
          for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i) || '';
            if (!k.startsWith('studio.gym.draft.')) continue;
            const d = JSON.parse(localStorage.getItem(k) || 'null');
            /* the website's draftHasWork: not saved, and a step done or a set ticked or typed */
            if (d && !d.saved && ((d.did || []).length > 0
              || (d.cards || []).some((c) => (c.sets || []).some((x) => x && (x.done || x.typed))))) return true;
          }
          return false;
        } catch (e) { return false; }
        """
}
