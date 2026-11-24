import Foundation

/// Which pages open inside Virt's web view, and which go to another app. Each door (`Door`) has its own:
///
/// - Tyler's (the default everywhere, so his path is exactly as before): the studio and its sign-in stay inside:
///   studio.tyleralocke.com (and the rest of tyleralocke.com), Cloudflare Access's sign-in pages (the team's
///   *.cloudflareaccess.com), Cloudflare's own check pages, and the sign-in pages of the identity providers Access can
///   send to.
/// - A friend's: train.time2play.live only. The studio, tyleralocke.com and everything else open in Safari, so nothing
///   of Tyler's ever shows inside a friend's Virt. (Their sign-in is native, Sign in with Apple, not a page.)
///
/// Anything else a link opens in the main window goes to Safari, because it isn't part of Training. Embedded frames
/// (a video, a check box) load where they are.
public enum Navigation {
    public static let home = URL(string: "https://studio.tyleralocke.com/training")!
    /// Training for friends (#578): the website's own Training screens on the friend's data.
    public static let friendHost = "train.time2play.live"
    public static let friendHome = URL(string: "https://\(friendHost)/")!
    /// Try a workout with no account (the website's #806, behind its `training-guest` switch).
    public static let guestPath = "/try"
    public static let guestHome = URL(string: "https://\(friendHost)\(guestPath)")!

    /// Bundled mode (tyleralocke#822): Training's screens served from inside the app at `virt-app://train/`, the
    /// same paths as the site. Only ever a friend's door (everyone's, since the studio's sign-in left Virt).
    public static let bundleScheme = "virt-app"
    public static let bundleHost = "train"
    public static let bundleOrigin = "\(bundleScheme)://\(bundleHost)"
    public static let bundledHome = URL(string: "\(bundleOrigin)/")!
    public static let bundledGuestHome = URL(string: "\(bundleOrigin)\(guestPath)")!
    /// The same test in the page's own words, for the scripts Virt runs there.
    static let bundledCheck = "location.protocol === '\(bundleScheme):' && location.host === '\(bundleHost)'"

    /// True for a page served from the bundle.
    public static func isBundled(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == bundleScheme && url?.host?.lowercased() == bundleHost
    }

    /// Where a message from the page may come from to count as the friends' Training: train.time2play.live over
    /// https, and in bundled mode the bundle's own origin. Nothing else.
    public static func isFriendOrigin(scheme: String, host: String, bundled: Bool) -> Bool {
        if scheme.lowercased() == "https" && host.lowercased() == friendHost { return true }
        return bundled && scheme.lowercased() == bundleScheme && host.lowercased() == bundleHost
    }

    /// In bundled mode, a link to one of the site's pages that the bundle has ("https://train.time2play.live/privacy")
    /// opens from the bundle instead. nil for anything else. `isPage` is the manifest's.
    public static func bundledPage(for url: URL?, isPage: (String) -> Bool) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == friendHost else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        guard isPage(path) else { return nil }
        return URL(string: bundleOrigin + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/"))
    }

    public enum Choice: Equatable, Sendable { case load, openOutside, block }

    static let insideHosts = ["tyleralocke.com", "cloudflareaccess.com", "challenges.cloudflare.com"]
    /// Identity providers Access could send to, if one is ever added (today it's a one-time PIN only).
    static let signInHosts = ["accounts.google.com", "login.microsoftonline.com", "appleid.apple.com", "github.com"]
    static let outsideSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "maps", "itms-apps", "itms-appss"]

    /// `bundled`: Training is being served from inside the app. Then the bundle's own pages are inside, and
    /// everything on the web, train.time2play.live's pages included, opens in Safari (the shell first sends a link
    /// to one of the bundle's pages to the bundle: `bundledPage`).
    public static func choose(_ url: URL?, mainFrame: Bool, door: Door = .tyler, bundled: Bool = false) -> Choice {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }
        switch scheme {
        case "about", "blob", "data": return .load
        case "http", "https": break
        case bundleScheme: return bundled && door == .friend && isBundled(url) ? .load : .block
        default: return outsideSchemes.contains(scheme) ? .openOutside : .block
        }
        if !mainFrame { return .load }
        return isInside(url, door: door, bundled: bundled) ? .load : .openOutside
    }

    /// True for the studio, its sign-in, and Cloudflare's check pages; for a friend, train.time2play.live only (in
    /// bundled mode, the bundle's pages only).
    public static func isInside(_ url: URL, door: Door = .tyler, bundled: Bool = false) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if door == .friend {
            if bundled { return isBundled(url) }
            return host == friendHost && url.scheme?.lowercased() == "https"
        }
        if insideHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if host == "github.com" { return url.path.hasPrefix("/login") || url.path.hasPrefix("/session") }
        return signInHosts.contains(host)
    }

    /// True while the page shown is studio Training (not the sign-in or another studio tab); for a friend, Training's
    /// page on train.time2play.live (its front page, not the privacy page).
    public static func isTraining(_ url: URL?, door: Door = .tyler, bundled: Bool = false) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        if door == .friend {
            let here = bundled ? isBundled(url) : host == friendHost
            return here && (url.path == "/" || url.path.isEmpty || url.path == guestPath)
        }
        return host == "studio.tyleralocke.com" && (url.path == "/training" || url.path.hasPrefix("/training/"))
    }

    /// True for Cloudflare Access's sign-in pages (a friend's door has none).
    public static func isSignIn(_ url: URL?, door: Door = .tyler) -> Bool {
        if door == .friend { return false }
        guard let host = url?.host?.lowercased() else { return false }
        return host.hasSuffix(".cloudflareaccess.com") || (url?.path.hasPrefix("/cdn-cgi/access") ?? false)
    }

    /// What opening Virt "to today" does (a widget tap, a reminder, Start my workout): Training's front page, unless
    /// a workout is going (never pull him off it), the sign-in is up (it lands on Training by itself), or nothing has
    /// loaded yet (the first load is Training already).
    public enum TodayAction: Equatable, Sendable { case stay, loadHome }

    public static func todayAction(current: URL?, midWorkout: Bool, door: Door = .tyler, bundled: Bool = false) -> TodayAction {
        guard let url = current else { return .stay }
        if isSignIn(url, door: door) || midWorkout { return .stay }
        if door == .friend { return isTraining(url, door: .friend, bundled: bundled) ? .stay : .loadHome }
        if isTraining(url) && (url.path == "/training" || url.path == "/training/") { return .stay }
        return .loadHome
    }

    /// The domains Virt's web view is bound to (Info.plist WKAppBoundDomains). Being bound is what lets Training's
    /// service worker run inside the app, so Training keeps working with no signal. Only main-frame pages are
    /// limited; embedded frames load from anywhere. iOS allows ten. train.time2play.live is the friends' Training, so
    /// the kinetic bridge (allowed only on bound domains) works for them too. The last one, with its colon, is a
    /// scheme, not a domain: WebKit reads an entry that ends in ":" as an app-bound scheme (WebKit bug 213889), which
    /// is what lets the bundle's pages at virt-app://train/ load in the bound web view with the bridge. A scheme
    /// counts toward the ten.
    public static let appBoundDomains = [
        "tyleralocke.com", "studio.tyleralocke.com", "proud-unit-177a.cloudflareaccess.com", "challenges.cloudflare.com",
        "accounts.google.com", "login.microsoftonline.com", "appleid.apple.com", "github.com", friendHost,
        "\(bundleScheme):",
    ]
}
