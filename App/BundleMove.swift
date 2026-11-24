import UIKit
import VirtCore
import WebKit

/// Moving from the old way (tyleralocke#822; the rules are VirtCore's `BundleMove`): on the first launch in bundled
/// mode on a phone that was signed in before, the old page (https://train.time2play.live/) is loaded once in a web
/// view nobody sees, with the session handed over as always, so it can send a workout it had saved on the phone. It
/// gets up to 10 seconds, less when it has nothing waiting. Then Virt opens Training from the bundle, for good.
@MainActor final class OldPageMove: NSObject, WKNavigationDelegate {
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: BundleMove.doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: BundleMove.doneKey) }
    }

    private static var tries: Int {
        get { UserDefaults.standard.integer(forKey: BundleMove.triesKey) }
        set { UserDefaults.standard.set(newValue, forKey: BundleMove.triesKey) }
    }

    private var web: WKWebView?
    private var then: (() -> Void)?
    private var loaded = false
    private var loadedAt = Date()
    private var deadline: DispatchWorkItem?
    private var poll: Timer?

    /// Loads the old page behind everything in `view`, and calls `then` once it's had its time.
    func run(session: FriendSession, behind view: UIView, then: @escaping () -> Void) {
        self.then = then
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // the same storage the old page always had
        config.applicationNameForUserAgent = "Virt/1.0"
        config.limitsNavigationsToAppBoundDomains = true  // as before bundles, so its service worker runs
        if let handover = FriendSignIn.handoverScript(token: session.token) {
            config.userContentController.addUserScript(WKUserScript(source: handover, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // in the window (so the page isn't put to sleep) but behind the real web view, and never touched or read out
        let w = WKWebView(frame: view.bounds, configuration: config)
        w.navigationDelegate = self
        w.isUserInteractionEnabled = false
        w.accessibilityElementsHidden = true
        w.isOpaque = false
        w.backgroundColor = .virtBlack
        view.insertSubview(w, at: 0)
        web = w
        let work = DispatchWorkItem { [weak self] in self?.timeUp() }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + BundleCheck.moveSeconds, execute: work)
        w.load(URLRequest(url: Navigation.friendHome))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // only the old page itself; nothing is ever sent to Safari from here
        let main = action.targetFrame?.isMainFrame ?? true
        decisionHandler(!main || Navigation.choose(action.request.url, mainFrame: true, door: .friend) == .load ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loaded else { return }
        loaded = true
        loadedAt = Date()
        // ask the page now and then whether anything is still waiting; once nothing is, it's done early
        poll = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ask(final: false) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !loaded { end(waiting: true) }  // the signal dropped: another launch
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !loaded { end(waiting: true) }
    }

    private func timeUp() {
        if loaded { ask(final: true) } else { end(waiting: true) }
    }

    private func ask(final: Bool) {
        guard let web else { return }
        web.evaluateJavaScript(BundleMove.waitingScript) { [weak self] value, _ in
            let waiting = (value as? Bool) ?? true
            Task { @MainActor in
                guard let self, self.web != nil else { return }
                // a moment after loading even with nothing waiting, so the page has read what it saved
                if final || (!waiting && Date().timeIntervalSince(self.loadedAt) >= 1.5) { self.end(waiting: waiting) }
            }
        }
    }

    private func end(waiting: Bool) {
        guard let w = web else { return }
        web = nil
        deadline?.cancel()
        poll?.invalidate()
        let result = BundleMove.after(loaded: loaded, waiting: waiting, tries: Self.tries)
        Self.tries = result.tries
        if result.done { Self.done = true }
        w.navigationDelegate = nil
        w.stopLoading()
        w.removeFromSuperview()
        let go = then
        then = nil
        go?()
    }
}
