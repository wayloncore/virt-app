import SwiftUI
import UIKit
import VirtCore
import WebKit

/// The web view around studio Training: the studio's own screens and data, with the `kinetic` bridge, the sign-in kept
/// inside the app, pull to refresh, a plain offline screen with Retry, and the status bar matched to the page.
final class ShellController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, PageCommands {
    private var web: WKWebView!
    private let statusBack = UIView()
    private let refresher = UIRefreshControl()
    private var errorHost: UIHostingController<OfflineView>?
    private var splash: UIView?
    private var observers: [NSKeyValueObservation] = []
    private var barStyle: UIStatusBarStyle = .lightContent
    private var downloads: [WKDownload: URL] = [:]
    private let startURL: URL
    private let testHTML: String?
    private let testing: Bool
    private var statusLine: UILabel?
    /// The saved copy has been tried once for the page that failed (OfflinePolicy).
    private var triedCache = false
    private var noSignal: UILabel?
    private var readyWork: DispatchWorkItem?
    /// The last load error, for the test build's status line.
    private var lastError = "none"

    init() {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        testing = ProcessInfo.processInfo.arguments.contains("-uitest")
        startURL = env["VIRT_START_URL"].flatMap(URL.init(string:)) ?? Navigation.home
        testHTML = env["VIRT_TEST_HTML"]
        #else
        testing = false
        startURL = Navigation.home
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
        // the offline check's made-up start page (localhost) isn't one of the studio's domains: that test loads it
        // unbound, with no bridge (WebKit allows the bridge only on bound domains)
        if ProcessInfo.processInfo.environment["VIRT_START_URL"] != nil { bound = false }
        #endif
        if bound {
            config.userContentController.add(BridgeHandler(), name: "kinetic")  // the website looks for exactly this name
            config.userContentController.addUserScript(WKUserScript(source: Self.startScript, injectionTime: .atDocumentStart,
                                                                    forMainFrameOnly: true))
        }
        // bound to the studio's domains (Info.plist WKAppBoundDomains): that's what lets Training's service worker
        // run in the app, so it keeps working with no signal. Other sites already open in Safari (Navigation).
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

        refresher.tintColor = .virtGold
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
        if testing { addTestStatus() }
        CookieKeeper.restore(into: config.websiteDataStore.httpCookieStore) { [weak self] in self?.loadStart() }
    }

    private func loadStart() {
        if let html = testHTML {
            web.loadHTMLString(html, baseURL: URL(string: "https://studio.tyleralocke.com/virt-bridge-test"))
        } else {
            web.load(URLRequest(url: startURL))
        }
    }

    /// Runs before the page's own scripts: tells Training that Virt plays the lead-in, zero, set and finish sounds
    /// itself (so the page can skip its own; an additive hint the page may ignore), and asks WebKit to mix the page's
    /// own sounds with his music.
    private static let startScript = """
        (() => {
          try { window.kineticApp = Object.freeze({ app: 'virt', version: 2, sounds: ['lead-in', 'zero', 'set', 'finish'] }); } catch (e) {}
          try { if (navigator.audioSession && navigator.audioSession.type === 'auto') navigator.audioSession.type = 'ambient'; } catch (e) {}
        })();
        """

    /// Saves the sign-in when the app goes to the background (SceneDelegate).
    func saveSignIn() {
        CookieKeeper.save(from: web.configuration.websiteDataStore.httpCookieStore)
    }

    // MARK: - Page commands (lock-screen buttons, Siri, widgets, reminders)

    func send(_ command: TimerCommand) { send(page: .timer(command)) }

    func send(page command: PageCommand) {
        // a little time in the background so the page can take it, if it's awake
        let task = UIApplication.shared.beginBackgroundTask(withName: "virt.command")
        web.evaluateJavaScript(command.script) { _, _ in
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    /// True while Training itself is showing (the test build's stand-in page counts).
    private var onTraining: Bool {
        if testHTML != nil { return web.url?.path.hasPrefix("/virt-bridge-test") ?? false }
        return Navigation.isTraining(web.url)
    }

    func goToToday(midWorkout: Bool) {
        if errorHost != nil { return retry() }
        if testHTML != nil { return }
        if Navigation.todayAction(current: web.url, midWorkout: midWorkout) == .loadHome {
            Engine.shared.pageLoading()
            web.load(URLRequest(url: Navigation.home))
        }
    }

    /// The page posted a message: it's up and listening.
    func pagePosted() {
        if onTraining { Engine.shared.pageReady() }
    }

    // MARK: - Virt's own sheets

    func askAboutReminders() {
        if let p = presentedViewController {
            Engine.shared.askNote = "skipped: \(type(of: p)) up"
            return
        }
        let today = Engine.shared.today
        let host = UIHostingController(rootView: ReminderAskView(today: today) { [weak self] yes in
            yes ? Reminders.shared.turnOn() : Reminders.shared.turnOff()
            self?.dismiss(animated: true)
        })
        host.view.backgroundColor = .virtBlack
        host.overrideUserInterfaceStyle = .dark
        host.sheetPresentationController?.detents = [.medium()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        present(host, animated: true)
    }

    func showSettings() {
        if let p = presentedViewController { p.dismiss(animated: false) }
        let host = UIHostingController(rootView: SettingsView { [weak self] in self?.dismiss(animated: true) })
        present(host, animated: true)
    }

    // MARK: - Looks

    private func matchStatusBar() {
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
        let host = UIHostingController(rootView: OfflineView(detail: error.localizedDescription) { [weak self] in self?.retry() })
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

    private func retry() {
        triedCache = false
        errorHost?.willMove(toParent: nil)
        errorHost?.view.removeFromSuperview()
        errorHost?.removeFromParent()
        errorHost = nil
        if web.url == nil || testHTML != nil { loadStart() } else { web.reload() }
        updateStatusLine()
    }

    @objc private func pulled() {
        if web.url == nil { loadStart() } else { web.reload() }
    }

    /// A load failed. Training works offline in its service worker, so the offline screen shows only when there's
    /// no page at all, after trying the saved copy once (OfflinePolicy). A page that's already up stays up.
    private func failed(_ error: Error) {
        refresher.endRefreshing()
        let e = error as NSError
        lastError = "\(e.domain) \(e.code)"
        let failing = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if e.domain == WKError.errorDomain, e.code == WKError.Code.navigationAppBoundDomain.rawValue {
            // a page outside the studio's domains: Safari, not a dead end
            if let u = failing { UIApplication.shared.open(u) }
            return
        }
        let code = e.domain == NSURLErrorDomain ? e.code : nil
        switch OfflinePolicy.choose(urlErrorCode: code, hasPage: web.backForwardList.currentItem != nil, triedCache: triedCache) {
        case .ignore: break
        case .keepPage: showNoSignal()
        case .tryCache:
            triedCache = true
            web.load(URLRequest(url: failing ?? startURL, cachePolicy: .returnCacheDataDontLoad))
        case .showOffline: showError(error)
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
        l.backgroundColor = .virtGold
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
        var choice = Navigation.choose(action.request.url, mainFrame: main)
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
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        triedCache = false
        hideSplash()
        updateStatusLine()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresher.endRefreshing()
        hideSplash()
        matchStatusBar()
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
            if Navigation.choose(url, mainFrame: true) == .load { webView.load(action.request) } else { UIApplication.shared.open(url) }
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
        var actions: [(String, () -> Void)] = TimerCommand.allCases.map { c in (c.rawValue, { Engine.shared.command(c) }) }
        actions.append(("rest", { Engine.shared.startRest(seconds: 90) }))
        actions.append(("start", { Engine.shared.startToday() }))
        let buttons = UIStackView(arrangedSubviews: actions.map { name, run -> UIButton in
            let b = UIButton(type: .system, primaryAction: UIAction(title: name) { _ in run() })
            b.accessibilityIdentifier = "dbg-\(name)"
            b.tintColor = .virtGold
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
        let host = web?.url?.host ?? "none"
        l.text = Engine.shared.status + " · host \(host)" + (errorHost != nil ? " · offline screen" : "") + " · error \(lastError)"
        view.bringSubviewToFront(l.superview ?? l)
    }
}

/// Hands the page's messages to the Engine. A separate object, so WebKit's strong hold on it doesn't keep the
/// controller alive.
final class BridgeHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = BridgeMessage.decode(object: message.body) else { return }
        let main = message.frameInfo.isMainFrame
        Task { @MainActor in
            Engine.shared.receive(m)
            if main, let shell = Engine.shared.page as? ShellController { shell.pagePosted() }
        }
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
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image("VirtMark").resizable().scaledToFit().frame(width: 72, height: 72).opacity(0.9)
            Text("Can't reach the studio").font(.title2.weight(.semibold)).foregroundStyle(.white)
            Text("Check the connection, then try again. A workout in progress is saved on the page and picks up where it was.")
                .font(.body).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
            Button(action: retry) {
                Text("Retry").font(.headline).frame(maxWidth: 220).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.virtGold)
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
    static let virtBlack = UIColor(red: 0x0B / 255, green: 0x0A / 255, blue: 0x09 / 255, alpha: 1)

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
