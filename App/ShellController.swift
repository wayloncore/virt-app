import AuthenticationServices
import SwiftUI
import UIKit
import VirtCore
import WebKit

/// The web view around Training: studio Training through Tyler's door, or train.time2play.live through a friend's
/// (Account.swift), with the `kinetic` bridge, the sign-in kept inside the app, pull to refresh, a plain offline screen
/// with Retry, and the status bar matched to the page. With no door yet, the first screen (DoorsView) asks.
final class ShellController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, PageCommands, PrefsPage {
    private var web: WKWebView!
    private let statusBack = UIView()
    private let refresher = UIRefreshControl()
    private var errorHost: UIHostingController<OfflineView>?
    private var splash: UIView?
    private var observers: [NSKeyValueObservation] = []
    private var barStyle: UIStatusBarStyle = .lightContent
    private var downloads: [WKDownload: URL] = [:]
    /// The test build's start page (VIRT_START_URL), instead of the door's.
    private let startOverride: URL?
    private let testHTML: String?
    /// The door in use; nil while the first screen asks.
    private(set) var door: Door?
    /// A friend's session (the friend's door only).
    private var friendSession: FriendSession?
    private var doorsHost: UIHostingController<DoorsView>?
    /// The web view is bound to the app's domains (always, but for the test build's made-up offline page).
    private var bound = true
    /// Where Training starts for this door.
    /// Trying a workout with no account (the first screen's second button): the friends' door with no session, on
    /// the website's /try page. Never saved: the next launch shows the first screen again, and the page keeps the
    /// guest's workout on the phone.
    private var guest = false
    private var startURL: URL {
        if let o = startOverride { return o }
        if bundled { return guest ? Navigation.bundledGuestHome : Navigation.bundledHome }
        return (guest ? Navigation.guestHome : door?.home) ?? Navigation.home
    }
    /// Bundled mode (tyleralocke#822): Training's screens are served from inside the app (BundleStore has a usable
    /// version) at virt-app://train/, for the friends' door, the owner's session and a guest. Otherwise everything
    /// here is exactly as before bundles: the website.
    private var bundled: Bool { bound && startOverride == nil && door == .friend && BundleStore.shared.bundled }
    /// The 8-second watch on a bundle version that has never started before (BundleCheck.startSeconds).
    private var startWatch: DispatchWorkItem?
    /// The one-time hidden load of the old page (BundleMove.swift), while it runs.
    private var mover: OldPageMove?
    private let testing: Bool
    private var statusLine: UILabel?
    /// The saved copy has been tried once for the page that failed (OfflinePolicy).
    private var triedCache = false
    /// The offline screen has been skipped once for this page with a quiet second try (reset when a page shows).
    private var retriedQuietly = false
    /// The error that sent us to the saved copy: the real reason, shown on the offline screen in place of the
    /// saved-copy try's own "cancelled".
    private var firstError: Error?
    private var noSignal: UILabel?
    private var readyWork: DispatchWorkItem?
    /// The last load error, for the test build's status line.
    private var lastError = "none"

    init() {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        testing = ProcessInfo.processInfo.arguments.contains("-uitest")
        startOverride = env["VIRT_START_URL"].flatMap(URL.init(string:))
        testHTML = env["VIRT_TEST_HTML"]
        #else
        testing = false
        startOverride = nil
        testHTML = nil
        _ = env
        #endif
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var preferredStatusBarStyle: UIStatusBarStyle { barStyle }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .virtBlack
        statusBack.backgroundColor = .virtBlack

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // cookies (the studio's sign-in) persist between launches
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "Virt/1.0"
        var bound = true
        #if DEBUG
        // the offline check's made-up start page (a .invalid host) isn't one of the studio's domains: that test loads it
        // unbound, with no bridge (WebKit allows the bridge only on bound domains)
        if ProcessInfo.processInfo.environment["VIRT_START_URL"] != nil { bound = false }
        #endif
        self.bound = bound
        if bound {
            config.userContentController.add(BridgeHandler(), name: "kinetic")  // the website looks for exactly this name
            // Virt's own: the friend's page says its "Sign out here" was tapped (FriendSignIn.signOutWatchScript)
            let account = AccountHandler()
            account.shell = self
            config.userContentController.add(account, name: "virtAccount")
        }
        // bound to the studio's domains (Info.plist WKAppBoundDomains): that's what lets Training's service worker
        // run in the app, so it keeps working with no signal. Other sites already open in Safari (Navigation).
        // The bundle's own scheme, virt-app: (Info.plist lists it in WKAppBoundDomains as "virt-app:", which is how
        // WebKit takes a scheme as app-bound), so virt-app://train/ loads in this same bound web view, with the
        // bridge and the scripts below, and its fetch() calls go to https://train.time2play.live with CORS.
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: Navigation.bundleScheme)
        config.limitsNavigationsToAppBoundDomains = bound

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .virtBlack
        web.scrollView.backgroundColor = .virtBlack
        // the page (viewport-fit=cover) pads for the home indicator itself; the web view starts below the status bar
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.accessibilityIdentifier = "studio"

        refresher.tintColor = .virtAccent
        refresher.addTarget(self, action: #selector(pulled), for: .valueChanged)
        web.scrollView.refreshControl = refresher

        for v in [statusBack, web!] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            statusBack.topAnchor.constraint(equalTo: view.topAnchor),
            statusBack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // the status bar takes the page's color (its theme color, or the color behind the page)
        observers.append(web.observe(\.themeColor, options: [.new]) { [weak self] _, _ in self?.matchStatusBar() })
        observers.append(web.observe(\.url, options: [.new]) { [weak self] _, _ in self?.updateStatusLine() })

        showSplash()
        Engine.shared.page = self
        PrefsHub.shared.page = self
        if testing { addTestStatus() }
        CookieKeeper.restore(into: config.websiteDataStore.httpCookieStore) { [weak self] in self?.pickDoor() }
    }

    private func loadStart() {
        guard let door else { return }
        triedCache = false  // a fresh start: nothing left over from the door before
        firstError = nil
        if let html = testHTML, !bundled {
            let base = door == .friend ? Navigation.friendHome : URL(string: "https://studio.tyleralocke.com/virt-bridge-test")!
            web.loadHTMLString(html, baseURL: base)
        } else {
            web.load(URLRequest(url: startURL))
        }
    }

    // MARK: - The doors (Account.swift)

    /// At launch: the saved door, or the first screen. A phone still on the studio's Cloudflare sign-in (Tyler's, from
    /// before Apple sign-in) gets the first screen once, so his Apple ID opens his Training (Door.atLaunch, #732).
    private func pickDoor() {
        // bundled, and no one signed in on this phone: there's nothing in the old page's storage to move (BundleMove)
        if BundleStore.shared.bundled, !OldPageMove.done, FriendKeeper.load() == nil { OldPageMove.done = true }
        if let saved = DoorStore.saved { return launchDoor(saved: saved, usedBefore: true) }
        DoorStore.usedBefore(cookies: web.configuration.websiteDataStore.httpCookieStore) { [weak self] used in
            self?.launchDoor(saved: nil, usedBefore: used)
        }
    }

    private func launchDoor(saved: String?, usedBefore: Bool) {
        let plain = Door.resolve(saved: saved, usedBefore: usedBefore)
        let d = Door.atLaunch(saved: saved, usedBefore: usedBefore, appleAsked: DoorStore.appleAsked, studioAllowed: testing)
        if plain == .tyler && d == nil {
            DoorStore.appleAsked = true
            DoorStore.studioUsed = true  // this is Tyler's phone: an unlinked Apple ID is asked to link, never made a friend
            return openDoor(nil, note: "Sign in with Apple to open your Training.")
        }
        if saved == nil, d == .tyler { DoorStore.choose(.tyler) }
        openDoor(d)
    }

    /// Opens Training through a door, or the first screen (nil).
    private func openDoor(_ d: Door?, note: String? = nil) {
        guest = false
        friendSession = nil
        if d == .friend {
            guard let s = FriendKeeper.load(), s.usable(now: Date()) else {
                FriendKeeper.clear()
                DoorStore.leave()
                return openDoor(nil, note: "Your sign-in ran out. Sign in again.")
            }
            friendSession = s
        }
        door = d
        if d == .tyler { DoorStore.studioUsed = true }
        installScripts()
        guard d != nil else { return showDoors(note: note) }
        hideDoors()
        startTraining()
        if d == .friend { checkFriend() }
        updateStatusLine()
    }

    /// Opens Training. In bundled mode, on a phone that was signed in before bundles, the old page is first loaded
    /// once where nobody sees it, to send a workout it may have saved on the phone (BundleMove); with no signal
    /// that waits for a later launch, and Training opens from the bundle now.
    private func startTraining() {
        guard bundled, !guest, !testing, let s = friendSession else { return loadStart() }
        switch BundleMove.step(done: OldPageMove.done, hasSession: true, online: BundleStore.shared.online) {
        case .go, .later:
            loadStart()
        case .doneAndGo:
            OldPageMove.done = true
            loadStart()
        case .run:
            let move = OldPageMove()
            mover = move
            move.run(session: s, behind: view) { [weak self] in
                guard let self else { return }
                self.mover = nil
                if self.door == .friend, self.friendSession == s { self.loadStart() }
            }
        }
    }

    /// "Try a workout": the guest page, with no sign-in and nothing handed over.
    private func openGuest() {
        friendSession = nil
        guest = true
        door = .friend
        installScripts()
        hideDoors()
        loadStart()
        updateStatusLine()
    }

    /// The guest page's "Sign in with Apple" (its `signIn` message): Virt's own first screen, over the workout,
    /// with the way back to it. Signing in opens their Training, where the page keeps the workout they just did.
    func guestWantsSignIn() {
        guard guest, doorsHost == nil else { return }
        showDoors(note: "Sign in to keep your workout, your plan and your history.")
    }

    /// The scripts each page gets before its own run: Virt's start hint, and on a friend's door the session handed
    /// to train.time2play.live and the watch for its "Sign out here".
    /// The settings the start script carries now, and whether a change is waiting for a load to finish.
    private var installedPrefs: AppPrefs?
    private var prefsStale = false

    private func installScripts() {
        guard bound else { return }
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        // with Virt's settings for the You tab (kineticApp.prefs); installed again whenever one changes, so every load
        // starts with the current values
        let prefs = PrefsHub.shared.current
        installedPrefs = prefs
        prefsStale = false
        ucc.addUserScript(WKUserScript(source: PageStart.script(build: BundleStore.shared.build, prefs: prefs),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let bundled = self.bundled
        // bundled: the page is told where its API is, and the session goes to the bundle's own page as well
        if bundled { ucc.addUserScript(WKUserScript(source: PageStart.apiBaseScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        if door == .friend, let s = friendSession, let handover = FriendSignIn.handoverScript(token: s.token, bundled: bundled) {
            ucc.addUserScript(WKUserScript(source: handover, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.addUserScript(WKUserScript(source: FriendSignIn.signOutWatch(bundled: bundled), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    /// A friend's session that the server says is gone: back to the first screen. No signal changes nothing.
    private func checkFriend() {
        if testing { return }  // the test build's session is made up
        guard let s = friendSession else { return }
        Task { @MainActor in
            if await FriendAPI.check(s) == false, self.door == .friend, self.friendSession == s {
                self.leaveDoor(note: "Your sign-in ran out. Sign in again.", signOutOnServer: false)
            }
        }
    }

    /// Signs out of the door in use and shows the first screen (Virt's settings, the friend's page signing out, a
    /// session that ran out, a deleted account). The next person sees nothing of the last one's: the widgets,
    /// reminders and Siri's "today" start fresh, a friend's session and their page's data on this phone are gone, and
    /// Tyler's studio sign-in is gone (Training's own copy on the phone stays, so nothing he hasn't sent is lost).
    func leaveDoor(note: String? = nil, signOutOnServer: Bool = true) {
        let was = door
        let session = friendSession
        // his Apple ID opened his Training on this phone (builds before this one didn't note it): remember, so the
        // first screen never offers the studio's sign-in again
        if session?.owner == true { DoorStore.ownerOpened = true }
        let wasBundled = bundled
        cancelStartWatch()
        door = nil
        friendSession = nil
        DoorStore.leave()
        installScripts()
        Engine.shared.startFresh()
        if presentedViewController != nil { dismiss(animated: true) }
        web.stopLoading()
        let data = web.configuration.websiteDataStore
        switch was {
        case .friend?:
            FriendKeeper.clear()
            if signOutOnServer, let s = session { Task { await FriendAPI.signOut(s) } }
            let all = WKWebsiteDataStore.allWebsiteDataTypes()
            // bundled: the page's data is kept under the bundle's own origin, whatever WebKit calls that record, so
            // everything goes but the studio's (which a friend's door never opens anyway)
            let studio = ["tyleralocke.com", "cloudflareaccess.com"]
            data.fetchDataRecords(ofTypes: all) { records in
                data.removeData(ofTypes: all, for: records.filter { r in
                    r.displayName.hasSuffix("time2play.live") || (wasBundled && !studio.contains { r.displayName.hasSuffix($0) })
                }) {}
            }
            // and the page clears its own, in case the record goes by a name we didn't expect
            if wasBundled, Navigation.isBundled(web.url) { web.evaluateJavaScript(Self.forgetScript) { _, _ in } }
        case .tyler?:
            CookieKeeper.signOut(of: data.httpCookieStore) {}
        case nil:
            break
        }
        web.load(URLRequest(url: URL(string: "about:blank")!))
        showDoors(note: note)
    }

    /// Run on the bundled page as someone signs out: everything the page kept on this phone goes.
    private static let forgetScript = """
        (() => { try { localStorage.clear(); sessionStorage.clear();
          if (indexedDB.databases) indexedDB.databases().then((l) => l.forEach((d) => indexedDB.deleteDatabase(d.name)));
          if (window.caches) caches.keys().then((k) => k.forEach((n) => caches.delete(n))); } catch (e) {} return true; })()
        """

    /// The friend tapped the page's own "Sign out here".
    func pageSignedOut() {
        guard door == .friend else { return }
        leaveDoor()
    }

    /// Delete account (Virt's settings, a friend only): a fresh Sign in with Apple so the server can revoke it, then
    /// the server deletes the Time2Play account and all of its Training. nil when it's done; otherwise why not.
    func deleteFriendAccount() async -> String? {
        guard door == .friend, let s = friendSession, !s.isOwner else { return "Only a friend's account can be deleted here." }
        var code: String?
        do {
            let c = try await AppleAuth().request()
            code = c.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        } catch {
            if (error as? ASAuthorizationError)?.code == .canceled { return "Not deleted." }
            // no fresh code: the server still deletes everything, it just can't revoke Sign in with Apple
        }
        guard await FriendAPI.delete(s, authorizationCode: code) else {
            return "Couldn't delete the account. Check the connection and try again."
        }
        leaveDoor(note: "Your account and its training are deleted.", signOutOnServer: false)
        return nil
    }

    private func showDoors(note: String?) {
        hideSplash()
        removeError()
        hideDoors()
        let host = UIHostingController(rootView: DoorsView(opened: { [weak self] d in
            DoorStore.choose(d)
            self?.openDoor(d)
        }, note: note, studioUsed: DoorStore.studioUsed, tryLabel: guest ? "Back to the workout" : "Try a workout",
           tryIt: { [weak self] in
               guard let self else { return }
               if self.guest { self.hideDoors(); self.updateStatusLine() } else { self.openGuest() }
           }))
        host.view.backgroundColor = .virtBlack
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        doorsHost = host
        barStyle = .lightContent
        setNeedsStatusBarAppearanceUpdate()
        updateStatusLine()
    }

    private func hideDoors() {
        guard let h = doorsHost else { return }
        h.willMove(toParent: nil)
        h.view.removeFromSuperview()
        h.removeFromParent()
        doorsHost = nil
    }

    /// Saves the sign-in when the app goes to the background (SceneDelegate).
    func saveSignIn() {
        CookieKeeper.save(from: web.configuration.websiteDataStore.httpCookieStore)
    }

    // MARK: - Page commands (lock-screen buttons, Siri, widgets, reminders)

    func send(_ command: TimerCommand) { send(page: .timer(command)) }

    func send(page command: PageCommand) { send(page: command) { _ in } }

    func send(page command: PageCommand, done: @escaping @MainActor (Bool) -> Void) {
        // a little time in the background so the page can take it, if it's awake
        let task = UIApplication.shared.beginBackgroundTask(withName: "virt.command")
        web.evaluateJavaScript(command.script) { _, error in
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            // an error means the script never ran (the page's process was ended, say); the script itself can't throw
            MainActor.assumeIsolated { done(error == nil) }
        }
    }

    /// True while Training itself is showing (the test build's stand-in page counts).
    private var onTraining: Bool {
        guard let door else { return false }
        if testHTML != nil {
            return door == .friend ? Navigation.isTraining(web.url, door: .friend, bundled: bundled) : (web.url?.path.hasPrefix("/virt-bridge-test") ?? false)
        }
        return Navigation.isTraining(web.url, door: door, bundled: bundled)
    }

    func goToToday(midWorkout: Bool) {
        guard let door else { return }  // the first screen is up: nothing to open yet
        if errorHost != nil { return retry() }
        if testHTML != nil { return }
        if guest { return }  // a guest's page is the whole of it: nothing to go back to
        if Navigation.todayAction(current: web.url, midWorkout: midWorkout, door: door, bundled: bundled) == .loadHome {
            Engine.shared.pageLoading()
            web.load(URLRequest(url: bundled ? Navigation.bundledHome : door.home))
        }
    }

    /// The page posted a message: it's up and listening.
    func pagePosted() {
        bridgeSpoke()
        if onTraining { Engine.shared.pageReady() }
    }

    // MARK: - The bundle's first start (tyleralocke#822)

    /// The page said something on the `kinetic` bridge. From the bundled page, that's the proof this version of
    /// the bundle works: the watch is called off, and the version isn't watched again.
    func bridgeSpoke() {
        guard bundled, Navigation.isBundled(web.url) else { return }
        cancelStartWatch()
        BundleStore.shared.proved()
    }

    /// A version of the bundle that has never spoken on the bridge gets 8 seconds from the moment Training starts
    /// to load. (A version that has is trusted: a slow phone never fails a bundle that works.)
    private func watchStart(of url: URL?) {
        cancelStartWatch()
        guard bundled, BundleStore.shared.needsWatch, Navigation.isTraining(url, door: .friend, bundled: true) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bundleDidNotStart()
        }
        startWatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + BundleCheck.startSeconds, execute: work)
    }

    /// Called off when the app leaves the screen (a page in the background is paused, which proves nothing), and
    /// whenever another load takes over.
    func cancelStartWatch() {
        startWatch?.cancel()
        startWatch = nil
    }

    /// No bridge message in time: this version is never tried again, and Training reloads from the one before it,
    /// then the shipped copy, then the website.
    private func bundleDidNotStart() {
        startWatch = nil
        guard bundled, UIApplication.shared.applicationState != .background else { return }
        BundleStore.shared.failActive()
        leaveBrokenBundle()
    }

    /// The web view wouldn't open the bundle's page at all: no bundle for the rest of this launch (the website, as
    /// before), without holding it against any version.
    private func bundleWouldNotLoad() {
        cancelStartWatch()
        BundleStore.shared.giveUp()
        leaveBrokenBundle()
    }

    private func leaveBrokenBundle() {
        installScripts()  // the scripts say whether the page is bundled
        web.stopLoading()
        loadStart()
        updateStatusLine()
    }

    // MARK: - Virt's own sheets

    func askAboutReminders() {
        if let p = presentedViewController {
            Engine.shared.askNote = "skipped: \(type(of: p)) up"
            return
        }
        let today = Engine.shared.today
        let host = UIHostingController(rootView: ReminderAskView(today: today) { [weak self] yes in
            self?.dismiss(animated: true) {
                // after the sheet is gone, so iOS's own question (or the way to Settings) has a clear screen
                if yes { Reminders.shared.turnOn { [weak self] in Reminders.offerSettings(from: self) } } else { Reminders.shared.turnOff() }
            }
        })
        host.view.backgroundColor = .virtBlack
        host.overrideUserInterfaceStyle = .dark
        host.sheetPresentationController?.detents = [.medium()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        present(host, animated: true)
    }

    // MARK: - Settings through the bridge (the You tab)

    /// A setting changed (the sheet, the page, or iOS's notification setting): the next load starts with it, and the
    /// page showing now hears `kinetic:prefs`.
    func prefsChanged(_ prefs: AppPrefs) {
        // The start scripts are put back only when a value really changed, and never while a page is loading: taking
        // them out and putting them in again mid-load can leave that page without its session or its sign-out watch.
        // A change during a load waits for the load to finish (didFinish).
        if prefs != installedPrefs {
            if web.isLoading { prefsStale = true } else { installScripts() }
        }
        guard onTraining, doorsHost == nil else { return }
        web.evaluateJavaScript(prefs.eventScript) { _, _ in }
        updateStatusLine()
    }

    /// What the page asked on the bridge (VirtCore's AppRequest; the handler has checked it's Training's own main
    /// frame). Sign out and Delete account follow the settings sheet's rules and show its own confirmations.
    func pageAsked(_ r: AppRequest) {
        guard door != nil, doorsHost == nil else { return }
        let hub = PrefsHub.shared
        switch r {
        case .setSounds(let on): hub.setSounds(on)
        case .setSoundStyle(let st): hub.setStyle(st, preview: SoundBoard.shared.enabled && st != SoundBoard.shared.style)
        case .setReminders(let on): hub.setRemindersFromPage(on)
        case .setLockAfter(let l): hub.setLockAfter(l)
        case .openNotificationSettings: hub.openNotificationSettings()
        case .signOut, .deleteAccount:
            let ask = AccountAsk.decide(r, door: door, owner: friendSession?.isOwner == true, guest: guest,
                                        midWorkout: Engine.shared.board.midWorkout(now: Date()))
            accountAsk(ask)
        }
    }

    private func accountAsk(_ ask: AccountAsk) {
        let a: UIAlertController
        switch ask {
        case .ignore:
            return
        case .finishFirst:
            a = UIAlertController(title: nil, message: AccountAsk.finishFirstLine, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .cancel))
        case .confirmSignOut:
            a = UIAlertController(title: AccountCopy.signOutTitle, message: AccountCopy.signOutMessage(door), preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Sign out", style: .destructive) { [weak self] _ in self?.leaveDoor() })
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        case .confirmDelete:
            a = UIAlertController(title: AccountCopy.deleteTitle, message: AccountCopy.deleteMessage, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let why = await self.deleteFriendAccount() else { return }
                    let n = UIAlertController(title: nil, message: why, preferredStyle: .alert)
                    n.addAction(UIAlertAction(title: "OK", style: .cancel))
                    self.presentOrSkip(n) {}
                }
            })
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        }
        presentOrSkip(a) {}
    }

    /// The page asked for Virt's settings (its Account row).
    func settingsFromPage() {
        guard door != nil, !guest, doorsHost == nil, presentedViewController == nil else { return }
        showSettings()
    }

    func showSettings() {
        if let p = presentedViewController { p.dismiss(animated: false) }
        let account = SettingsAccount(door: door, name: friendSession?.name ?? "",
                                      owner: friendSession?.isOwner == true,
                                      midWorkout: Engine.shared.board.midWorkout(now: Date()),
                                      leave: { [weak self] in self?.leaveDoor() },
                                      delete: { [weak self] in await self?.deleteFriendAccount() },
                                      apple: { [weak self] in await self?.appleFromStudio() },
                                      studio: { [weak self] in self?.studioFromOwner() })
        let host = UIHostingController(rootView: SettingsView(account: account) { [weak self] in self?.dismiss(animated: true) })
        present(host, animated: true)
    }

    // MARK: - Tyler's own Training with Apple (#732)

    /// Settings → Sign in with Apple, on the studio's sign-in: Sign in with Apple, link that Apple ID to his studio
    /// Training from the studio page already open here (behind Access, so only he can), then his Training opens on
    /// the train host. Waits if a workout hasn't been sent yet. The studio's sign-in stays as the fallback. nil when
    /// it's done; otherwise why not.
    func appleFromStudio() async -> String? {
        guard door == .tyler else { return "Open the studio sign-in first." }
        guard web.url?.host == "studio.tyleralocke.com" else { return "Open the studio's Training first (sign in with the studio's email code), then try again." }
        if (try? await web.callAsyncJavaScript(OwnerSignIn.waitingScript, arguments: [:], contentWorld: .page)) as? Bool == true {
            return "A workout on this phone hasn't been sent yet. Open Training with a signal so it sends, then try again."
        }
        let token: String
        do {
            let c = try await AppleAuth().request()
            guard let t = c.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else { return "Couldn't sign in with Apple. Try again." }
            token = t
        } catch {
            if (error as? ASAuthorizationError)?.code == .canceled { return "Not changed." }
            return "Couldn't sign in with Apple. Try again."
        }
        var outcome = await FriendAPI.ownerSignIn(identityToken: token)
        if case .notLinked(let code) = outcome {
            let r = try? await web.callAsyncJavaScript(OwnerSignIn.linkScript, arguments: ["code": code], contentWorld: .page)
            let j = r as? [String: Any]
            guard j?["ok"] as? Bool == true else {
                let why = (j?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The studio didn't answer."
                return "Couldn't link your Apple ID: \(why) You can link it by hand in the studio: Training, Profile, code \(code)."
            }
            outcome = await FriendAPI.ownerSignIn(identityToken: token)
        }
        guard case .owner(let s) = outcome else { return "Your Training with Apple isn't on yet. Nothing changed; the studio sign-in still works." }
        FriendKeeper.save(s)
        DoorStore.ownerOpened = true
        if presentedViewController != nil { dismiss(animated: true) }
        DoorStore.choose(.friend)
        openDoor(.friend)
        return nil
    }

    /// Settings → Use the studio sign-in, from Tyler's Apple sign-in: back to the studio (Cloudflare) door. The
    /// owner session ends; Sign in with Apple in Settings brings it back.
    func studioFromOwner() {
        guard door == .friend, let s = friendSession, s.isOwner else { return }
        FriendKeeper.clear()
        Task { await FriendAPI.signOut(s) }
        if presentedViewController != nil { dismiss(animated: true) }
        DoorStore.choose(.tyler)
        openDoor(.tyler)
    }

    // MARK: - Looks

    private func matchStatusBar() {
        if doorsHost != nil { return }  // the first screen is black, whatever's in the web view behind it
        if let c = web.themeColor { return paintStatusBar(c) }
        // no theme color (Access's sign-in page): the page's own background
        web.evaluateJavaScript(Self.backgroundScript) { [weak self] v, _ in
            guard let self, self.web.themeColor == nil else { return }
            self.paintStatusBar(UIColor(css: v as? String) ?? .white)
        }
    }

    private static let backgroundScript = """
        (() => { const b = document.body && getComputedStyle(document.body).backgroundColor;
          return !b || b === 'rgba(0, 0, 0, 0)' ? getComputedStyle(document.documentElement).backgroundColor : b; })()
        """

    private func paintStatusBar(_ c: UIColor) {
        statusBack.backgroundColor = c
        barStyle = c.isLight ? .darkContent : .lightContent
        setNeedsStatusBarAppearanceUpdate()
    }

    private func showSplash() {
        let s = UIView()
        s.backgroundColor = .virtBlack
        let mark = UIImageView(image: UIImage(named: "VirtMark"))
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        s.addSubview(mark)
        s.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: view.topAnchor), s.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            s.leadingAnchor.constraint(equalTo: view.leadingAnchor), s.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mark.centerXAnchor.constraint(equalTo: s.centerXAnchor), mark.centerYAnchor.constraint(equalTo: s.centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 120), mark.heightAnchor.constraint(equalToConstant: 120),
        ])
        splash = s
    }

    private func hideSplash() {
        guard let s = splash else { return }
        splash = nil
        UIView.animate(withDuration: 0.25, animations: { s.alpha = 0 }, completion: { _ in s.removeFromSuperview() })
    }

    // MARK: - Offline / error

    private func showError(_ error: Error) {
        refresher.endRefreshing()
        hideSplash()
        errorHost?.view.removeFromSuperview()
        let ns = error as NSError
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? "no address"
        // the reason in full (what failed, where), so a screenshot of this screen says what to fix
        let detail = "\(ns.localizedDescription) (\(ns.domain) \(ns.code), \(failing))"
        let host = UIHostingController(rootView: OfflineView(detail: detail,
                                                             place: door == .friend ? "Training" : "the studio") { [weak self] in self?.retry() })
        host.view.backgroundColor = .virtBlack
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        errorHost = host
        barStyle = .lightContent
        setNeedsStatusBarAppearanceUpdate()
        if let s = statusLine { view.bringSubviewToFront(s) }
        updateStatusLine()
    }

    private func removeError() {
        errorHost?.willMove(toParent: nil)
        errorHost?.view.removeFromSuperview()
        errorHost?.removeFromParent()
        errorHost = nil
    }

    private func retry() {
        triedCache = false
        removeError()
        if web.url == nil || web.url?.scheme == "about" || testHTML != nil { loadStart() } else { web.reload() }
        updateStatusLine()
    }

    @objc private func pulled() {
        if web.url == nil || web.url?.scheme == "about" { loadStart(); refresher.endRefreshing() } else { web.reload() }
    }

    /// A load failed. Training works offline in its service worker, so the offline screen shows only when there's
    /// no page at all, after trying the saved copy once (OfflinePolicy). A page that's already up stays up.
    private func failed(_ error: Error) {
        refresher.endRefreshing()
        let e = error as NSError
        lastError = "\(e.domain) \(e.code)"
        let failing = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if e.domain == WKError.errorDomain, e.code == WKError.Code.navigationAppBoundDomain.rawValue {
            // the bundle's own page was refused as not app-bound (it shouldn't be: "virt-app:" is in the list): the
            // website instead, never a dead end
            if bundled, failing == nil || Navigation.isBundled(failing) { return bundleWouldNotLoad() }
            // a page outside the studio's domains: Safari, not a dead end
            if let u = failing { UIApplication.shared.open(u) }
            return
        }
        let code = e.domain == NSURLErrorDomain ? e.code : nil
        // a load that was cancelled because another one took its place (the page handing over a sign-in, a redirect)
        // isn't a failure: the new one is already on its way
        if code == NSURLErrorCancelled, web.isLoading { return updateStatusLine() }
        switch OfflinePolicy.choose(urlErrorCode: code, hasPage: web.backForwardList.currentItem != nil, triedCache: triedCache) {
        case .ignore: break
        case .keepPage: showNoSignal()
        case .tryCache:
            triedCache = true
            firstError = error
            web.load(URLRequest(url: failing ?? startURL, cachePolicy: .returnCacheDataDontLoad))
        case .showOffline:
            // right after signing in, the first load can be cut short once; try again quietly before saying so
            if !retriedQuietly {
                retriedQuietly = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.retry() }
            } else {
                showError(firstError ?? error)
            }
        }
        updateStatusLine()
    }

    /// A short note over a page that stays up with no signal.
    private func showNoSignal() {
        noSignal?.removeFromSuperview()
        let l = PaddedLabel()
        l.text = "No signal. Training keeps working on this phone."
        l.font = .preferredFont(forTextStyle: .footnote)
        l.textColor = .virtBlack
        l.backgroundColor = .virtAccent
        l.layer.cornerRadius = 14
        l.clipsToBounds = true
        l.textAlignment = .center
        l.accessibilityIdentifier = "no-signal"
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            l.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        noSignal = l
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak l] in
            UIView.animate(withDuration: 0.3, animations: { l?.alpha = 0 }, completion: { _ in l?.removeFromSuperview() })
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        let main = action.targetFrame?.isMainFrame ?? true
        // bundled: a link to one of the site's pages that the bundle has (Privacy, Terms) opens from the bundle
        if bundled, main, let page = bundledPage(for: action.request.url) {
            webView.load(URLRequest(url: page))
            return decisionHandler(.cancel)
        }
        var choice = Navigation.choose(action.request.url, mainFrame: main, door: door ?? .tyler, bundled: bundled)
        #if DEBUG
        if choice == .openOutside, action.request.url?.host == startURL.host { choice = .load }  // the tests' start page
        #endif
        switch choice {
        case .load:
            if action.targetFrame == nil {  // target=_blank inside the studio: open it here
                webView.load(action.request)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        case .openOutside:
            if let url = action.request.url { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
        case .block:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        readyWork?.cancel()
        Engine.shared.pageLoading()
        watchStart(of: webView.url)
    }

    private func bundledPage(for url: URL?) -> URL? {
        guard let manifest = BundleStore.shared.active?.manifest else { return nil }
        return Navigation.bundledPage(for: url, isPage: { manifest.isPage($0) })
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        triedCache = false
        // a page is showing: an offline screen from a moment ago comes down (about:blank after signing out isn't one)
        if webView.url?.scheme != "about" { retriedQuietly = false; removeError() }
        hideSplash()
        updateStatusLine()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresher.endRefreshing()
        hideSplash()
        matchStatusBar()
        // a setting changed while this page was loading: the next load starts with it, and this page hears it now
        if prefsStale {
            installScripts()
            if onTraining, doorsHost == nil { web.evaluateJavaScript(PrefsHub.shared.current.eventScript) { _, _ in } }
        }
        updateStatusLine()
        // Training listens for commands once its scripts have run; a message from the page says so sooner
        readyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.onTraining else { return }
            Engine.shared.pageReady()
        }
        readyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - Downloads (Training's share picture, when sharing isn't offered): saved, then the share sheet

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
        downloads[download] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloads.removeValue(forKey: download) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads[download] = nil
    }

    // MARK: - WKUIDelegate: the page's confirm() and alert() as native alerts, and new windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if bundled, let page = bundledPage(for: url) {
                webView.load(URLRequest(url: page))
            } else if Navigation.choose(url, mainFrame: true, door: door ?? .tyler, bundled: bundled) == .load {
                webView.load(action.request)
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presentOrSkip(a) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presentOrSkip(a) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        presentOrSkip(a) { completionHandler(nil) }
    }

    private func presentOrSkip(_ a: UIAlertController, otherwise: () -> Void) {
        guard presentedViewController == nil, view.window != nil else { return otherwise() }
        present(a, animated: true)
    }

    // MARK: - The test build's status line (UI tests read it)

    private func addTestStatus() {
        let l = UILabel()
        l.numberOfLines = 0
        l.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        l.textColor = .white
        l.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        l.accessibilityIdentifier = "virt-status"
        l.translatesAutoresizingMaskIntoConstraints = false
        // each runs the Live Activity's own intent, the way the system does for a lock-screen press
        let press: (TimerCommand) -> Void = { c in _ = Task { _ = try? await TimerCommandIntent(c).perform() } }
        var actions: [(String, () -> Void)] = TimerCommand.allCases.map { c in (c.rawValue, { press(c) }) }
        // three Log set presses in the same moment (a double tap, or iOS handing one press over more than once)
        actions.append(("log3", { for _ in 0..<3 { press(.log) } }))
        // Log set with the page asleep (or no page: iOS started Virt just for the press): held, then handed over
        // when the page is up again
        actions.append(("logheld", {
            Engine.shared.pageAsleepForTest()
            press(.log)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Engine.shared.pageReady() }
        }))
        actions.append(("rest", { Engine.shared.startRest(seconds: 90) }))
        actions.append(("start", { Engine.shared.startToday() }))
        actions.append(("settings", { [weak self] in self?.showSettings() }))
        // the page loaded again (the stand-in page can't reload itself: its address isn't really it)
        actions.append(("reload", { [weak self] in self?.loadStart() }))
        let buttons = UIStackView(arrangedSubviews: actions.map { name, run -> UIButton in
            let b = UIButton(type: .system, primaryAction: UIAction(title: name) { _ in run() })
            b.accessibilityIdentifier = "dbg-\(name)"
            b.tintColor = .virtAccent
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            return b
        })
        buttons.distribution = .fillEqually
        buttons.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        let stack = UIStackView(arrangedSubviews: [l, buttons])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
        ])
        statusLine = l
        Engine.shared.onChange = { [weak self] in self?.updateStatusLine() }
        updateStatusLine()
    }

    private func updateStatusLine() {
        guard let l = statusLine else { return }
        // the first screen shows on its own (its buttons sit where the status line does)
        l.superview?.isHidden = doorsHost != nil
        let host = web?.url?.host ?? "none"
        l.text = Engine.shared.status + " · host \(host)" + (errorHost != nil ? " · offline screen" : "") + " · error \(lastError)"
            + " · door \(door?.rawValue ?? (doorsHost != nil ? "asking" : "none"))\(guest ? " guest" : "")"
            + " · page \(String((web?.url?.absoluteString ?? "none").prefix(48)))"
            + " · bundle \(BundleStore.shared.active?.version ?? "none")\(BundleStore.shared.note)"
            + " · lock \(LockAfter(stored: UserDefaults.standard.string(forKey: LockAfter.key)).rawValue) · prefs sent \(PrefsHub.shared.sent)"
            + " · style \(SoundBoard.shared.style.rawValue)"
        view.bringSubviewToFront(l.superview ?? l)
    }
}

/// Hands the page's messages to the Engine. A separate object, so WebKit's strong hold on it doesn't keep the
/// controller alive.
final class BridgeHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let main = message.frameInfo.isMainFrame
        // Training's own page: train.time2play.live, or in bundled mode the bundle's origin (virt-app://train)
        let origin = message.frameInfo.securityOrigin
        let friend = Navigation.isFriendOrigin(scheme: origin.protocol, host: origin.host, bundled: BundleMode.on)
        // any message from the page's main frame, even one Virt doesn't read, says the page is up (the bundle's start watch)
        if main { Task { @MainActor in (Engine.shared.page as? ShellController)?.bridgeSpoke() } }
        // the You tab's settings, sign out and Delete account (VirtCore's AppRequest): only from Training's own main
        // frame; a bad key or value is ignored, and none of these ever goes to the Engine
        if AppRequest.isRequest(object: message.body) {
            guard AppRequest.allowed(isMainFrame: main, scheme: origin.protocol, host: origin.host, bundled: BundleMode.on),
                  let r = AppRequest.decode(object: message.body) else { return }
            Task { @MainActor in (Engine.shared.page as? ShellController)?.pageAsked(r) }
            return
        }
        if main, BridgeMessage.isGuestSignIn(object: message.body), friend {
            Task { @MainActor in (Engine.shared.page as? ShellController)?.guestWantsSignIn() }
            return
        }
        // You's "Account and app settings" row: Virt's own settings sheet (sign out, Delete account), one tap from
        // inside the app. Only from Training's own pages, and never for a guest (there's no account to manage).
        if main, BridgeMessage.isOpenSettings(object: message.body), friend || origin.host == "studio.tyleralocke.com" {
            Task { @MainActor in (Engine.shared.page as? ShellController)?.settingsFromPage() }
            return
        }
        guard let m = BridgeMessage.decode(object: message.body) else { return }
        Task { @MainActor in
            Engine.shared.receive(m)
            if main, let shell = Engine.shared.page as? ShellController { shell.pagePosted() }
        }
    }
}

/// Virt's own messages from a friend's page (not the website's `kinetic` bridge): only "signedOut", only from
/// train.time2play.live's main frame (in bundled mode, the bundle's own page too). A separate object, so WebKit's strong hold on it doesn't keep the controller alive.
final class AccountHandler: NSObject, WKScriptMessageHandler {
    weak var shell: ShellController?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, Navigation.isFriendOrigin(scheme: origin.protocol, host: origin.host, bundled: BundleMode.on),
              (message.body as? [String: Any])?["type"] as? String == "signedOut" else { return }
        Task { @MainActor in self.shell?.pageSignedOut() }
    }
}

/// A label with room around its text (the no-signal note).
final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 7)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height + 14)
    }
}

/// The plain offline screen: what happened, and Retry.
struct OfflineView: View {
    let detail: String
    /// "the studio" (Tyler's door) or "Training" (a friend's).
    var place = "the studio"
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image("VirtMark").resizable().scaledToFit().frame(width: 72, height: 72).opacity(0.9)
            Text("Can't reach \(place)").font(.title2.weight(.semibold)).foregroundStyle(.white)
            Text("Check the connection, then try again. A workout in progress is saved on the page and picks up where it was.")
                .font(.body).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
            Button(action: retry) {
                Text("Retry").font(.headline).frame(maxWidth: 220).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.virtAccent)
            .foregroundStyle(Color.virtBlack)
            .accessibilityIdentifier("retry")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.virtBlack)
    }
}

extension UIColor {
    static let virtGold = UIColor(red: 0xDF / 255, green: 0xC2 / 255, blue: 0x97 / 255, alpha: 1)
    /// v3 (#746): graphite and the one red, as Color's (Shared.swift).
    static let virtBlack = UIColor(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1B / 255, alpha: 1)
    static let virtAccent = UIColor(red: 0xFF / 255, green: 0x4B / 255, blue: 0x3A / 255, alpha: 1)

    /// A CSS color as getComputedStyle gives it: "rgb(r, g, b)" or "rgba(r, g, b, a)". nil if it's see-through.
    convenience init?(css: String?) {
        guard let css, let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let n = css[css.index(after: open)..<close].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count >= 3, (n.count < 4 || n[3] > 0.5) else { return nil }
        self.init(red: n[0] / 255, green: n[1] / 255, blue: n[2] / 255, alpha: 1)
    }

    /// True for a light color (dark status bar text on it).
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}
