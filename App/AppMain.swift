import Security
import SwiftUI
import UIKit
import VirtCore
import UserNotifications
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = AlertPresenter.shared
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            for k in [Reminders.Key.enabled, Reminders.Key.movedTo, SoundBoard.Key.enabled, SoundBoard.Key.style, SharedStore.localKey,
                      LockAfter.key, TimerBoard.Snapshot.key, LiveWorkout.Memory.key] {
                UserDefaults.standard.removeObject(forKey: k)
            }
            DoorStore.forget()
            FriendKeeper.clear()
        }
        // the test build's doors: `-uitest-door-none` (the first screen), `-uitest-door-friend` (a friend signed in with
        // VIRT_FRIEND_TOKEN, a made-up session), or Tyler's (every other test, as before doors)
        if ProcessInfo.processInfo.arguments.contains("-uitest") {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-uitest-door-none") {
                DoorStore.leave()  // asks, even if the simulator still has a studio cookie from another test
                // #732: the studio fallback shows only on a phone that used the studio; `-uitest-studio-used` is that phone
                DoorStore.studioUsed = args.contains("-uitest-studio-used")
                // his Apple ID has opened his Training here before: the studio's sign-in is never offered again
                DoorStore.ownerOpened = args.contains("-uitest-owner-opened")
            } else if args.contains("-uitest-door-friend") {
                DoorStore.choose(.friend)
                if let t = ProcessInfo.processInfo.environment["VIRT_FRIEND_TOKEN"] { FriendKeeper.save(FriendSession(token: t, name: "Sam")) }
            } else {
                DoorStore.choose(.tyler)
                // every other test is Tyler's studio door as before; `-uitest-apple-not-asked` is his phone from
                // before Apple sign-in, which gets the first screen once
                DoorStore.appleAsked = !args.contains("-uitest-apple-not-asked")
            }
        }
        #endif
        Engine.shared.launched()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var shell: ShellController?
    /// The Face ID lock (Lock.swift): its window covers this one from the first frame.
    private let lock = AppLock()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        let s = ShellController()
        w.rootViewController = s
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-widgets") {
            w.rootViewController = UIHostingController(rootView: WidgetGallery())
        }
        #endif
        w.tintColor = .virtAccent
        w.makeKeyAndVisible()
        window = w
        shell = s
        lock.attach(to: ws, over: w)
        // opened from a widget, a link or a quick action
        if let url = options.urlContexts.first?.url { open(url) }
        if let item = options.shortcutItem, let link = AppLink.quickAction(item.type) { DispatchQueue.main.async { self.go(link) } }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { open(url) }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let link = AppLink.quickAction(shortcutItem.type) else { return completionHandler(false) }
        go(link)
        completionHandler(true)
    }

    private func open(_ url: URL) {
        guard let link = AppLink.parse(url) else { return }
        DispatchQueue.main.async { self.go(link) }
    }

    /// Virt's own links: the widgets (today), Start my workout, a rest, and the settings sheet.
    private func go(_ link: AppLink) {
        switch link {
        case .today: Engine.shared.openToday()
        case .start: Engine.shared.startToday()
        case .rest(let s): Engine.shared.startRest(seconds: s)
        case .settings: shell?.showSettings()
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) { lock.willEnterForeground() }

    func sceneDidBecomeActive(_ scene: UIScene) {
        lock.didBecomeActive()
        Engine.shared.becameActive()
        // a newer set of Training's screens, if there is one (at most every 30 minutes, never during a workout);
        // it's used from the next launch
        BundleStore.shared.checkForUpdate(midWorkout: Engine.shared.liveWorkout(now: Date()))
    }

    func sceneWillResignActive(_ scene: UIScene) { lock.willResignActive() }

    func sceneDidEnterBackground(_ scene: UIScene) {
        lock.didEnterBackground()
        shell?.saveSignIn()
        shell?.cancelStartWatch()
    }
}

/// Keeps the studio's sign-in across launches. Cloudflare Access's sign-in can be a session cookie, which a web view
/// forgets when the app is closed; this keeps a copy of those cookies (only for tyleralocke.com and the Access sign-in)
/// in the Keychain on this phone, and puts them back on the next launch. Access still decides how long a sign-in lasts.
enum CookieKeeper {
    private static let service = "com.tyleralocke.virt.signin"
    private static let account = "session-cookies"
    private static let domains = ["tyleralocke.com", "cloudflareaccess.com"]

    static func save(from store: WKHTTPCookieStore) {
        store.getAllCookies { cookies in
            let keep = cookies.filter { c in
                c.isSessionOnly && domains.contains { c.domain == $0 || c.domain.hasSuffix("." + $0) }
            }
            let list: [[String: Any]] = keep.compactMap { c in
                guard let p = c.properties else { return nil }
                var out: [String: Any] = [:]
                for (k, v) in p where v is String || v is NSNumber || v is Date { out[k.rawValue] = v }
                return out
            }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0) else { return }
            write(data)
        }
    }

    static func restore(into store: WKHTTPCookieStore, then done: @escaping () -> Void) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") { write(Data()); return done() }
        #endif
        guard let data = read(), !data.isEmpty,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return done() }
        store.getAllCookies { have in
            let haveKeys = Set(have.map { "\($0.domain)|\($0.path)|\($0.name)" })
            let cookies = list.compactMap { p -> HTTPCookie? in
                var props: [HTTPCookiePropertyKey: Any] = [:]
                for (k, v) in p { props[HTTPCookiePropertyKey(k)] = v }
                return HTTPCookie(properties: props)
            }.filter { !haveKeys.contains("\($0.domain)|\($0.path)|\($0.name)") }
            guard !cookies.isEmpty else { return done() }
            let group = DispatchGroup()
            for c in cookies { group.enter(); store.setCookie(c) { group.leave() } }
            group.notify(queue: .main) { done() }
        }
    }

    /// A saved copy of the studio's sign-in is on this phone (DoorStore.usedBefore).
    static var hasCopy: Bool { !(read() ?? Data()).isEmpty }

    /// Signs the web view out of the studio and forgets the saved copy (signing out of Tyler's door in Virt's
    /// settings). Only the sign-in cookies: Training's own copy on this phone (workouts not sent yet) stays.
    static func signOut(of store: WKHTTPCookieStore, then done: @escaping () -> Void) {
        write(Data())
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for c in cookies where domains.contains(where: { c.domain == $0 || c.domain.hasSuffix("." + $0) }) {
                group.enter()
                store.delete(c) { group.leave() }
            }
            group.notify(queue: .main) { done() }
        }
    }

    private static func read() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func write(_ data: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !data.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
