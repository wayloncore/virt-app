import Foundation

/// What to do when a page load fails. Training works offline in its service worker (wayloncore/tyleralocke#533), so
/// Virt stays out of its way: the offline screen shows only when there's no page to show at all.
///
/// - A page is already up (a pull to refresh, a link, with no signal): keep it, with a short note.
/// - Nothing loaded yet: try the saved copy once (the web view's cache), then the offline screen.
/// - A cancelled or replaced load isn't a failure, except the saved-copy try itself: WebKit cancels it when
///   there's no saved copy, and that means offline.
public enum OfflinePolicy {
    public enum Choice: Equatable, Sendable { case ignore, keepPage, tryCache, showOffline }

    /// NSURLErrorCancelled (spelled out so this builds on Linux too).
    static let cancelled = -999

    /// `urlErrorCode` is the code of an NSURLErrorDomain error, or nil for any other kind of error.
    public static func choose(urlErrorCode: Int?, hasPage: Bool, triedCache: Bool) -> Choice {
        guard let code = urlErrorCode else { return .ignore }
        if code == cancelled { return triedCache && !hasPage ? .showOffline : .ignore }
        if hasPage { return .keepPage }
        return triedCache ? .showOffline : .tryCache
    }
}

/// How the zero sounds when other audio is playing. With nothing else playing the chime plays as ambient sound (it
/// mixes and follows the silent switch); with his music on it ducks the music for the moment of the chime, then
/// lets it come back up.
public enum ZeroMix: Equatable, Sendable {
    case mix, duck

    public static func choose(otherAudioPlaying: Bool) -> ZeroMix { otherAudioPlaying ? .duck : .mix }
}
