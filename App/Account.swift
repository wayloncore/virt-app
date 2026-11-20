import AuthenticationServices
import Security
import SwiftUI
import UIKit
import VirtCore
import WebKit

/// Training for friends (#578, part 2): the two doors into Virt, and the friend's Time2Play sign-in.
///
/// - Tyler's door is Cloudflare Access into studio Training, exactly as it always was (Face ID, CookieKeeper).
/// - The friend's door is Sign in with Apple, checked by the website's accounts server (tyleralocke.com/live/players/,
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

    /// For the test build's reset only.
    static func forget() { UserDefaults.standard.removeObject(forKey: Door.key) }

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

    /// The status (0: no answer) and body.
    static func send(_ path: String, method: String = "POST", body: Data? = nil, token: String? = nil) async -> (Int, Data) {
        var req = URLRequest(url: FriendSignIn.url(path))
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

    static func signIn(identityToken: String, name: String) async -> FriendSignIn.Outcome {
        await call("apple", body: FriendSignIn.appleBody(identityToken: identityToken, name: name, over13: true, app: appVersion))
    }

    /// Still signed in? false only when the server says the session is gone; nil when it can't tell (no signal).
    static func check(_ s: FriendSession) async -> Bool? {
        let (status, data) = await send("me", method: "GET", token: s.token)
        return FriendSignIn.stillSignedIn(status: status, body: data)
    }

    static func signOut(_ s: FriendSession) async { _ = await call("signout", body: Data("{}".utf8), token: s.token) }

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

// MARK: - The first screen: two doors

/// The first screen on a new phone (and after signing out of a door): Training for friends, or Tyler's studio.
struct DoorsView: View {
    /// A door was picked and is ready: the friend is signed in, or Tyler's studio was chosen.
    var opened: (Door) -> Void
    /// A note to show over the doors (a sign-in that ran out).
    var note: String?

    private enum Step { case doors, age, under13, apple, name }
    @State private var step: Step = .doors
    @State private var busy = false
    @State private var problem: String?
    @State private var pendingToken: String?
    @State private var typedName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("VirtMark").resizable().scaledToFit().frame(width: 76, height: 76)
                    .padding(.top, 36)
                    .accessibilityHidden(true)
                switch step {
                case .doors: doors
                case .age: age
                case .under13: under13
                case .apple: apple
                case .name: name
                }
                if let p = problem ?? (step == .doors ? note : nil) {
                    Text(p).font(.footnote).foregroundStyle(Color.virtGold).multilineTextAlignment(.center)
                        .accessibilityIdentifier("doors-problem")
                }
                if busy { ProgressView().tint(.virtGold).accessibilityIdentifier("doors-busy") }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.virtBlack.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doors")
    }

    // the two doors

    private var doors: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Welcome to Virt").font(.largeTitle.weight(.bold)).foregroundStyle(.white)
                Text("Pick how you sign in. Virt remembers, and you can switch in Settings.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            }
            .padding(.bottom, 6)
            DoorCard(symbol: "figure.strengthtraining.traditional", title: "Training for friends",
                     text: "Your own plan and workouts. Sign in with Apple. Only you see your training.") {
                Button { problem = nil; step = .age } label: {
                    Text("Get started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.virtGold)
                .foregroundStyle(Color.virtBlack)
                .accessibilityIdentifier("door-friend")
            }
            DoorCard(symbol: "lock.shield", title: "Tyler's studio",
                     text: "Tyler's own Training, behind the studio's email sign-in.") {
                Button { opened(.tyler) } label: {
                    Text("Open the studio").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.virtGold)
                .accessibilityIdentifier("door-tyler")
            }
            Text("No AI and no analytics. Your workouts go only to your own Training.")
                .font(.footnote).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    // the friend's steps

    private var age: some View {
        StepCard(title: "Are you 13 or older?", text: "Training for friends uses a Time2Play account, and those are for 13 and up.") {
            Button { step = .apple } label: {
                Text("Yes, I'm 13 or older").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.virtGold).foregroundStyle(Color.virtBlack)
            .accessibilityIdentifier("age-yes")
            Button { step = .under13 } label: { Text("No").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered).tint(.virtGold)
                .accessibilityIdentifier("age-no")
            back
        }
    }

    private var under13: some View {
        StepCard(title: "Not yet", text: "Training for friends is for 13 and up. Nothing was saved.") { back }
    }

    private var apple: some View {
        StepCard(title: "Sign in with Apple",
                 text: "This makes your Time2Play account (the same one the Time2Play app uses), or signs in to the one you have. Virt asks Apple for your first name only, never your email.") {
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
                    send(token: t, name: typedName)
                case .failure(let e):
                    if (e as? ASAuthorizationError)?.code == .canceled { return }
                    problem = "Couldn't sign in with Apple. Try again."
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .disabled(busy)
            .accessibilityIdentifier("apple-sign-in")
            back
        }
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
            .buttonStyle(.borderedProminent).tint(.virtGold).foregroundStyle(Color.virtBlack)
            .disabled(busy || FriendSignIn.cleanName(typedName) == nil)
            .accessibilityIdentifier("name-continue")
            back
        }
    }

    private var back: some View {
        Button("Back") { problem = nil; pendingToken = nil; step = .doors }
            .foregroundStyle(.white.opacity(0.75))
            .disabled(busy)
            .accessibilityIdentifier("doors-back")
    }

    private func sendName() {
        guard let t = pendingToken, let n = FriendSignIn.cleanName(typedName) else { return }
        send(token: t, name: n)
    }

    private func send(token: String, name: String) {
        busy = true
        problem = nil
        Task {
            let r = await FriendAPI.signIn(identityToken: token, name: name)
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
                step = .under13
            case .signedOut:
                problem = "That sign-in didn't go through. Try again."
                step = .apple
            case .failed(let why):
                problem = why
            }
        }
    }
}

private struct DoorCard<Action: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(Color.virtGold)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white)
            }
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.virtGold.opacity(0.25), lineWidth: 1))
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
