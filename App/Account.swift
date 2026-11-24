import AuthenticationServices
import Security
import SwiftUI
import UIKit
import VirtCore
import WebKit

/// Training for friends (#578, part 2) and one sign-in for everyone (#730, #732): Sign in with Apple, and the server
/// decides whose Training it is (Tyler's linked Apple ID: his own studio Training, as an owner session; anyone else:
/// their own Time2Play account).
///
/// - The studio's Cloudflare Access sign-in (the `tyler` door, Face ID, CookieKeeper) stays as Tyler's fallback, shown
///   only on a phone that has used it.
/// - Signing in with Apple is checked by the website's accounts server (tyleralocke.com/live/players/,
///   the same accounts the Time2Play app uses), then train.time2play.live with the session handed to the page before
///   it runs (VirtCore's `FriendSignIn.handoverScript`). The page swaps it for its own cookie.
///
/// Saved data (new keys only): the door in UserDefaults (`virt.door`), the friend's session in this phone's Keychain
/// (service `com.tyleralocke.virt.friend`). Nothing about workouts is kept here. No AI, no analytics.

/// The door this phone uses.
@MainActor enum DoorStore {
    static var saved: String? { UserDefaults.standard.string(forKey: Door.key) }

    static func choose(_ d: Door) { UserDefaults.standard.set(d.rawValue, forKey: Door.key) }

    /// Signed out of a door: the first screen asks again on the next launch.
    static func leave() { UserDefaults.standard.set(Door.none, forKey: Door.key) }

    /// This phone has been shown Sign in with Apple in place of the studio's sign-in (Door.atLaunch).
    static var appleAsked: Bool {
        get { UserDefaults.standard.bool(forKey: Door.appleAskedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Door.appleAskedKey) }
    }

    /// Tyler's own Apple ID has opened his Training on this phone (Door.ownerOpenedKey).
    static var ownerOpened: Bool {
        get { UserDefaults.standard.bool(forKey: Door.ownerOpenedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Door.ownerOpenedKey) }
    }

    /// For the test build's reset only.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: Door.ownerOpenedKey)
        UserDefaults.standard.removeObject(forKey: Door.appleAskedKey)
        UserDefaults.standard.removeObject(forKey: Door.key)
        UserDefaults.standard.removeObject(forKey: studioKey)
    }

    /// This phone has opened the studio's sign-in (#732): the first screen offers it, small, as a fallback. A new
    /// key; a friend's phone never sets it.
    static let studioKey = "virt.studio-used"
    static var studioUsed: Bool {
        get { UserDefaults.standard.bool(forKey: studioKey) || CookieKeeper.hasCopy }
        set { UserDefaults.standard.set(newValue, forKey: studioKey) }
    }

    /// True if this phone used Virt before doors existed (Tyler's own): a studio sign-in in the web view or its
    /// Keychain copy, a saved `today`, or his reminder or sound settings. Asked only while nothing is saved.
    static func usedBefore(cookies: WKHTTPCookieStore, then done: @escaping (Bool) -> Void) {
        let keys = [Reminders.Key.enabled, SoundBoard.Key.enabled, SoundBoard.Key.style, SharedStore.localKey]
        if CookieKeeper.hasCopy || SharedStore.loadToday() != nil || keys.contains(where: { UserDefaults.standard.object(forKey: $0) != nil }) {
            return done(true)
        }
        cookies.getAllCookies { all in
            let studio = all.contains { c in ["tyleralocke.com", "cloudflareaccess.com"].contains { c.domain == $0 || c.domain.hasSuffix("." + $0) } }
            DispatchQueue.main.async { done(studio) }
        }
    }
}

/// The friend's session, in this phone's Keychain only (never synced, never in a backup to another phone).
enum FriendKeeper {
    private static let service = "com.tyleralocke.virt.friend"
    private static let account = "session"

    #if DEBUG
    /// The unsigned simulator build can't use the Keychain (no entitlements); its tests keep a copy here instead.
    /// Debug only: a Release build keeps the session in the Keychain and nowhere else.
    private static let testKey = "virt.friend.test-session"
    #endif

    static func load() -> FriendSession? {
        #if DEBUG
        if let d = UserDefaults.standard.data(forKey: testKey) { return FriendSession.decode(d) }
        #endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return FriendSession.decode(d)
    }

    static func save(_ s: FriendSession) {
        guard let data = s.encoded() else { return }
        clear()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(add as CFDictionary, nil)
        #if DEBUG
        if status != errSecSuccess { UserDefaults.standard.set(data, forKey: testKey) }
        #else
        _ = status
        #endif
    }

    static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: testKey)
        #endif
    }
}

/// The friend's calls to the accounts server. Each carries only what it needs; the session goes in a header, never
/// in an address.
enum FriendAPI {
    static var appVersion: String {
        "virt \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"
    }

    static func call(_ path: String, method: String = "POST", body: Data? = nil, token: String? = nil) async -> FriendSignIn.Outcome {
        let (status, data) = await send(path, method: method, body: body, token: token)
        return FriendSignIn.outcome(status: status, body: data)
    }

    /// The status (0: no answer) and body. `url` overrides the accounts path (the owner's calls, on the train host).
    static func send(_ path: String, method: String = "POST", body: Data? = nil, token: String? = nil, url: URL? = nil) async -> (Int, Data) {
        var req = URLRequest(url: url ?? FriendSignIn.url(path))
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue(appVersion, forHTTPHeaderField: "x-t2p-app")
        if let b = body { req.httpBody = b; req.setValue("application/json", forHTTPHeaderField: "content-type") }
        if let t = token, FriendSession.tokenOk(t) { req.setValue("Bearer \(t)", forHTTPHeaderField: "authorization") }
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            return ((r as? HTTPURLResponse)?.statusCode ?? 0, d)
        } catch {
            return (0, Data())
        }
    }

    /// `over13` is the person's own answer; false until they've been asked. An account that exists ignores it, and a
    /// new one without it comes back as `.tooYoung`, which is when the first screen asks.
    static func signIn(identityToken: String, name: String, over13: Bool) async -> FriendSignIn.Outcome {
        await call("apple", body: FriendSignIn.appleBody(identityToken: identityToken, name: name, over13: over13, app: appVersion))
    }

    /// Still signed in? false only when the server says the session is gone; nil when it can't tell (no signal).
    /// The owner's session is checked where it lives, on the train host (#732).
    static func check(_ s: FriendSession) async -> Bool? {
        let (status, data) = s.isOwner
            ? await send("me", method: "GET", token: s.token, url: OwnerSignIn.url("me"))
            : await send("me", method: "GET", token: s.token)
        return FriendSignIn.stillSignedIn(status: status, body: data)
    }

    static func signOut(_ s: FriendSession) async {
        if s.isOwner { _ = await send("signout", body: Data("{}".utf8), token: s.token, url: OwnerSignIn.url("signout")); return }
        _ = await call("signout", body: Data("{}".utf8), token: s.token)
    }

    /// Tyler's own Training first (#732): his linked Apple ID gets an owner session; anyone else, "not linked".
    static func ownerSignIn(identityToken: String) async -> OwnerSignIn.Outcome {
        let (status, data) = await send("owner/apple", body: OwnerSignIn.appleBody(identityToken: identityToken), url: OwnerSignIn.url("owner/apple"))
        return OwnerSignIn.outcome(status: status, body: data)
    }

    /// Deletes the Time2Play account and all of its Training (the server wipes both).
    static func delete(_ s: FriendSession, authorizationCode: String?) async -> Bool {
        let (status, _) = await send("delete", body: FriendSignIn.deleteBody(authorizationCode: authorizationCode), token: s.token)
        return (200..<300).contains(status)
    }
}

/// A fresh Sign in with Apple outside the button (Delete account asks for one, so the server can revoke it).
@MainActor final class AppleAuth: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var done: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var controller: ASAuthorizationController?

    func request() async throws -> ASAuthorizationAppleIDCredential {
        let r = ASAuthorizationAppleIDProvider().createRequest()
        r.requestedScopes = []
        let c = ASAuthorizationController(authorizationRequests: [r])
        c.delegate = self
        c.presentationContextProvider = self
        controller = c
        defer { controller = nil }
        return try await withCheckedThrowingContinuation { k in
            done = k
            c.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization a: ASAuthorization) {
        Task { @MainActor in
            if let c = a.credential as? ASAuthorizationAppleIDCredential { done?.resume(returning: c) } else { done?.resume(throwing: ASAuthorizationError(.failed)) }
            done = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            done?.resume(throwing: error)
            done = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

// MARK: - The first screen: Sign in with Apple (#730, #732)

/// The first screen on a new phone (and after signing out): one way in, Sign in with Apple. The server decides whose
/// Training it is: Tyler's linked Apple ID opens his own (an owner session), anyone else their own Time2Play account.
/// The studio's Cloudflare sign-in is gone from Virt (Tyler, Nov 23); only the test build still opens that door.
struct DoorsView: View {
    /// Signed in: `.friend` (an owner or friend session is in FriendKeeper), or `.tyler` (the studio's sign-in).
    var opened: (Door) -> Void
    /// A note to show on the first step (a sign-in that ran out).
    var note: String?
    /// This phone has used the studio's sign-in (Tyler's): an unlinked Apple ID is asked to link, not made a friend.
    var studioUsed = false

    /// Sign in with Apple is on the first screen, and nothing comes before or after it but a new person's name
    /// (Tyler, Nov 23: no age question). The first screen says Virt is for 13 and up, and signing in confirms it;
    /// `over13` stays true. The question screen is kept for the day it's wanted again, and nothing leads to it.
    private enum Step: Equatable { case welcome, age, under13, name, notLinked(String) }
    @State private var over13 = true
    @State private var step: Step = .welcome
    @State private var busy = false
    @State private var problem: String?
    @State private var pendingToken: String?
    @State private var typedName = ""

    var body: some View {
        Group {
            if step == .welcome { first } else { steps }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doors")
    }

    /// The first screen (Tyler, Nov 23): the whole screen, pure black like the intro it comes from. His VIRT word
    /// (the intro clip's own frame, so the pillar I is his artwork, never re-lettered), one line under it, and
    /// Sign in with Apple at the bottom with the small print. Nothing else.
    private var first: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Image("VirtWord").resizable().scaledToFit()
                .frame(maxWidth: 440)
                .accessibilityLabel("Virt")
                .accessibilityIdentifier("virt-word")
            Text("Strength is a virtue. Build it daily.")
                .font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .accessibilityIdentifier("welcome-line")
            Spacer(minLength: 20)
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                if let p = problem ?? note {
                    Text(p).font(.footnote).foregroundStyle(Color.virtAccent).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("doors-problem")
                }
                if busy { ProgressView().tint(.virtAccent).accessibilityIdentifier("doors-busy") }
                appleButton
                Text("For ages 13 and up. [Terms](https://train.time2play.live/terms) · [Privacy](https://train.time2play.live/privacy)")
                    .font(.footnote).foregroundStyle(.white.opacity(0.55)).tint(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("first-small-print")
            }
            .frame(maxWidth: 420)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What can follow the first screen: a new person's name, or (Tyler's phone only) linking his studio.
    private var steps: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("VirtMark").resizable().scaledToFit().frame(width: 76, height: 76)
                    .padding(.top, 36)
                    .accessibilityHidden(true)
                switch step {
                case .welcome: EmptyView()
                case .age: age
                case .under13: under13
                case .name: name
                case .notLinked(let code): notLinked(code)
                }
                if let p = problem {
                    Text(p).font(.footnote).foregroundStyle(Color.virtAccent).multilineTextAlignment(.center)
                        .accessibilityIdentifier("doors-problem")
                }
                if busy { ProgressView().tint(.virtAccent).accessibilityIdentifier("doors-busy") }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { r in
            r.requestedScopes = [.fullName]
        } onCompletion: { result in
            switch result {
            case .success(let a):
                guard let c = a.credential as? ASAuthorizationAppleIDCredential,
                      let t = c.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                    problem = "Couldn't sign in with Apple. Try again."
                    return
                }
                typedName = c.fullName?.givenName ?? ""
                send(token: t, name: typedName, askOwner: true)
            case .failure(let e):
                if (e as? ASAuthorizationError)?.code == .canceled { return }
                problem = "Couldn't sign in with Apple. Try again."
            }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 52)
        .disabled(busy)
        .accessibilityIdentifier("apple-sign-in")
    }

    /// Asked after Sign in with Apple, and only when the server says this Apple ID has no account yet.
    private var age: some View {
        StepCard(title: "Are you 13 or older?", text: "Virt uses a Time2Play account, and those are for 13 and up.") {
            Button {
                over13 = true
                guard let t = pendingToken else { step = .welcome; return }
                send(token: t, name: typedName, askOwner: false)
            } label: {
                Text("Yes, I'm 13 or older").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.virtAccent).foregroundStyle(Color.virtBlack)
            .disabled(busy)
            .accessibilityIdentifier("age-yes")
            Button { pendingToken = nil; step = .under13 } label: { Text("No").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered).tint(.virtAccent)
                .disabled(busy)
                .accessibilityIdentifier("age-no")
            back
        }
    }

    private var under13: some View {
        StepCard(title: "Not yet", text: "Virt is for 13 and up. Nothing was saved.") { back }
    }

    private var name: some View {
        StepCard(title: "What should we call you?", text: "Your first name or a nickname. Friends you add in Time2Play see it; your training stays yours.") {
            TextField("Name", text: $typedName)
                .textContentType(.givenName)
                .submitLabel(.continue)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
                .accessibilityIdentifier("name-field")
                .onSubmit(sendName)
            Button(action: sendName) {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.virtAccent).foregroundStyle(Color.virtBlack)
            .disabled(busy || FriendSignIn.cleanName(typedName) == nil)
            .accessibilityIdentifier("name-continue")
            back
        }
    }

    /// Only on Tyler's phone: an Apple ID that isn't linked to his Training yet. It's never turned into a Time2Play
    /// account without asking. He links it once in the studio on the web (the studio's sign-in is no longer in Virt).
    private func notLinked(_ code: String) -> some View {
        StepCard(title: "Link your Apple ID first",
                 text: "This Apple ID isn't linked to your Training yet. In the studio on the web, open Training, You, Settings, Sign in from Virt, and enter the code \(code). Then come back and try again.") {
            Button {
                guard let t = pendingToken else { step = .welcome; return }
                send(token: t, name: typedName, askOwner: true)
            } label: {
                Text("Try again").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.virtAccent).foregroundStyle(Color.virtBlack)
            .disabled(busy)
            .accessibilityIdentifier("link-retry")
            Button {
                guard let t = pendingToken else { step = .welcome; return }
                send(token: t, name: typedName, askOwner: false)
            } label: { Text("Use a Time2Play account instead").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered).tint(.virtAccent)
                .disabled(busy)
                .accessibilityIdentifier("as-friend")
            back
        }
    }

    private var back: some View {
        Button("Back") { problem = nil; pendingToken = nil; step = .welcome }
            .foregroundStyle(.white.opacity(0.75))
            .disabled(busy)
            .accessibilityIdentifier("doors-back")
    }

    private func sendName() {
        guard let t = pendingToken, let n = FriendSignIn.cleanName(typedName) else { return }
        send(token: t, name: n, askOwner: false)
    }

    /// The owner path first (`askOwner`), then the person's own Time2Play account.
    private func send(token: String, name: String, askOwner: Bool) {
        busy = true
        problem = nil
        Task {
            if askOwner {
                let answer = await FriendAPI.ownerSignIn(identityToken: token)
                var session: FriendSession?
                var code: String?
                if case .owner(let s) = answer { session = s }
                if case .notLinked(let c) = answer { code = c }
                switch Door.ownerStep(owner: session != nil, notLinked: code != nil, studioUsed: studioUsed,
                                      ownerOpened: DoorStore.ownerOpened) {
                case .open:
                    if let session { FriendKeeper.save(session) }
                    DoorStore.ownerOpened = true
                    busy = false
                    pendingToken = nil
                    return opened(.friend)
                case .link:
                    busy = false
                    pendingToken = token
                    step = .notLinked(code ?? "")
                    return
                case .sayUnreachable:
                    // his phone, and his Training didn't answer: say so; never open a friend's account by accident
                    busy = false
                    problem = "Couldn't reach your Training just now. Check the connection and try again."
                    return
                case .goOnAsFriend:
                    break
                }
            }
            let r = await FriendAPI.signIn(identityToken: token, name: name, over13: over13)
            busy = false
            switch r {
            case .signedIn(let s):
                FriendKeeper.save(s)
                pendingToken = nil
                opened(.friend)
            case .needsName:
                pendingToken = token
                step = .name
                if FriendSignIn.cleanName(name) != nil { problem = "Pick a name of at least two characters." }
            case .tooYoung:
                // a new account: ask the 13+ question once, then send the same sign-in with the answer
                if over13 { pendingToken = nil; step = .under13 } else { pendingToken = token; step = .age }
            case .signedOut:
                problem = "That sign-in didn't go through. Try again."
                pendingToken = nil
                step = .welcome
            case .failed(let why):
                problem = why
            }
        }
    }
}

private struct StepCard<Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.title2.weight(.bold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
}
