import Foundation

/// Which pages open inside Virt's web view, and which go to another app.
///
/// The studio and its sign-in stay inside: studio.tyleralocke.com (and the rest of tyleralocke.com), Cloudflare
/// Access's sign-in pages (the team's *.cloudflareaccess.com), Cloudflare's own check pages, and the sign-in pages of
/// the identity providers Access can send to. Anything else a link opens in the main window goes to Safari, because
/// it isn't part of Training. Embedded frames (a video, a check box) load where they are.
public enum Navigation {
    public static let home = URL(string: "https://studio.tyleralocke.com/training")!

    public enum Choice: Equatable, Sendable { case load, openOutside, block }

    static let insideHosts = ["tyleralocke.com", "cloudflareaccess.com", "challenges.cloudflare.com"]
    /// Identity providers Access could send to, if one is ever added (today it's a one-time PIN only).
    static let signInHosts = ["accounts.google.com", "login.microsoftonline.com", "appleid.apple.com", "github.com"]
    static let outsideSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "maps", "itms-apps", "itms-appss"]

    public static func choose(_ url: URL?, mainFrame: Bool) -> Choice {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }
        switch scheme {
        case "about", "blob", "data": return .load
        case "http", "https": break
        default: return outsideSchemes.contains(scheme) ? .openOutside : .block
        }
        if !mainFrame { return .load }
        return isInside(url) ? .load : .openOutside
    }

    /// True for the studio, its sign-in, and Cloudflare's check pages.
    public static func isInside(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if insideHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if host == "github.com" { return url.path.hasPrefix("/login") || url.path.hasPrefix("/session") }
        return signInHosts.contains(host)
    }

    /// True while the page shown is studio Training (not the sign-in or another studio tab).
    public static func isTraining(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        return host == "studio.tyleralocke.com" && (url.path == "/training" || url.path.hasPrefix("/training/"))
    }

    /// True for Cloudflare Access's sign-in pages.
    public static func isSignIn(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.hasSuffix(".cloudflareaccess.com") || (url?.path.hasPrefix("/cdn-cgi/access") ?? false)
    }

    /// What opening Virt "to today" does (a widget tap, a reminder, Start my workout): Training's front page, unless
    /// a workout is going (never pull him off it), the sign-in is up (it lands on Training by itself), or nothing has
    /// loaded yet (the first load is Training already).
    public enum TodayAction: Equatable, Sendable { case stay, loadHome }

    public static func todayAction(current: URL?, midWorkout: Bool) -> TodayAction {
        guard let url = current else { return .stay }
        if isSignIn(url) || midWorkout { return .stay }
        if isTraining(url) && (url.path == "/training" || url.path == "/training/") { return .stay }
        return .loadHome
    }

    /// The domains Virt's web view is bound to (Info.plist WKAppBoundDomains). Being bound is what lets Training's
    /// service worker run inside the app, so Training keeps working with no signal. Only main-frame pages are
    /// limited; embedded frames load from anywhere. iOS allows ten.
    public static let appBoundDomains = [
        "tyleralocke.com", "studio.tyleralocke.com", "proud-unit-177a.cloudflareaccess.com", "challenges.cloudflare.com",
        "accounts.google.com", "login.microsoftonline.com", "appleid.apple.com", "github.com",
    ]
}
