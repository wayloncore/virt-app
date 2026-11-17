import Security
import UIKit
import UserNotifications
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = AlertPresenter.shared
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
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
        w.tintColor = .virtGold
        w.makeKeyAndVisible()
        window = w
        shell = s
        lock.attach(to: ws, over: w)
    }

    func sceneWillEnterForeground(_ scene: UIScene) { lock.willEnterForeground() }

    func sceneDidBecomeActive(_ scene: UIScene) {
        lock.didBecomeActive()
        Engine.shared.becameActive()
    }

    func sceneWillResignActive(_ scene: UIScene) { lock.willResignActive() }

    func sceneDidEnterBackground(_ scene: UIScene) {
        lock.didEnterBackground()
        shell?.saveSignIn()
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
