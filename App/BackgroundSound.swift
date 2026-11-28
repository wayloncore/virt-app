import AVFoundation
import UIKit
import VirtCore

/// The zero sound with the phone locked, and no banner (Tyler, Nov 27). VirtCore's `SoundKeeper` has the rules; this
/// is the audio. While a workout is going and Virt isn't on the screen (and Sounds is on), it holds the audio session
/// in `.playback` with `.mixWithOthers` (his music keeps playing, untouched: no ducking while locked), keeps Virt
/// running with a silent loop (the `audio` background mode), and schedules each zero's sound with
/// `AVAudioPlayer.play(atTime:)`. Engine tells it what's ahead on every timer change.
///
/// Each zero's sound includes its three-second count-in (Tyler, Nov 27: "start it around 3 seconds not 1 second"):
/// one player per zero, built by `CountInSound` (App/Sound.swift) from the style's tick and zero sound, so its beats
/// and its zero are exactly a second apart whatever the phone is doing. It starts at the first beat that fits
/// (VirtCore's `LeadIn.beats`). A pause, ±15 or skip inside the count-in stops it (`SoundKeeper.keeps`), and the new
/// zero gets its own.
///
/// When it stops, the session goes back to `.ambient` (the app's own sounds then follow the silent switch, as before).
/// A call, Siri or an alarm interrupts it: those zeros are silent (no notification, in any case), and it comes back when
/// the interruption ends, or at the next timer change after `SoundKeeper.retryAfter` if iOS never says it ended.
@MainActor final class BackgroundSound {
    static let shared = BackgroundSound()

    private(set) var state: SoundKeeper.State = .off
    /// Engine refreshes when the state changes on its own (an interruption, a route change).
    var onChange: (() -> Void)?

    private var loop: AVAudioPlayer?
    /// The scheduled zeros, by key, with when each was set to start (its first beat) and its zero.
    private var players: [String: (player: AVAudioPlayer, playAt: Date, zeroAt: Date)] = [:]
    /// Zeros whose sound has started (so the app's own chime never plays one again).
    private var started: Set<String> = []
    private var failedAt: Date?
    private var observing = false
    /// True while the session is in `.playback` for the keeper (until it's handed back as `.ambient`).
    private(set) var sessionHeld = false
    /// For the test build's status line: the states it has been in this launch.
    private(set) var history: [String] = []

    /// The next zero's sound (its count-in's first beat), for the test build's status line.
    var nextCueAt: Date? { players.values.map(\.playAt).filter { $0 > Date() }.min() }

    /// True when this zero's sound is the keeper's (scheduled or already started): the app doesn't play it too.
    func covers(_ key: String) -> Bool { started.contains(key) || (state.covers && players[key] != nil) }

    /// The app's own count-in for this zero has started (Virt was open): the keeper never plays it too.
    func appStarted(_ key: String) { started.insert(key) }

    /// Runs the keeper (or not) and schedules exactly these zeros.
    func update(run: Bool, cues: [SoundKeeper.Cue], now: Date) {
        observe()
        // a count-in already sounding whose zero went (paused, moved, skipped, Sounds off) stops, even with Virt open
        prune(cues, now: now)
        guard run else { return stop() }
        let waited = failedAt.map { now.timeIntervalSince($0) >= SoundKeeper.retryAfter } ?? true
        if state == .off || ((state == .failed || state == .interrupted) && waited) {
            start()
        }
        guard state.covers else { return }
        schedule(cues, now: now)
    }

    // MARK: - The session and the silent loop

    private func start() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            sessionHeld = true
            try s.setActive(true)
            let l = try loop ?? AVAudioPlayer(data: Self.silence)
            l.numberOfLoops = -1
            l.volume = 0
            loop = l
            guard l.play() else { throw KeeperError.loopWouldNotPlay }
            set(.on)
        } catch {
            failedAt = Date()
            set(.failed)
            loop?.stop()
            releaseSession()
        }
    }

    /// Everything stops; a sound already playing finishes. The session goes back to how the app holds it normally.
    private func stop() {
        guard state != .off || sessionHeld || loop?.isPlaying == true else { return }
        cancelUnstarted(now: Date())
        loop?.stop()
        failedAt = nil
        set(.off)
        // a zero's sound still playing keeps the session until it ends (deactivating would cut it off)
        let left = players.values.filter { $0.player.isPlaying }.map { $0.player.duration - $0.player.currentTime }.max() ?? 0
        if left > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.2) { [weak self] in
                guard let self, self.state == .off else { return }
                self.releaseSession()
            }
        } else {
            releaseSession()
        }
    }

    /// The session back to how the app holds it normally: `.ambient`, mixing with his music, following the silent switch.
    private func releaseSession() {
        guard sessionHeld else { return }
        sessionHeld = false
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? s.setCategory(.ambient, options: [.mixWithOthers])
    }

    private func set(_ s: SoundKeeper.State) {
        guard s != state else { return }
        state = s
        history.append(s.rawValue)
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    // MARK: - The zeros

    private func schedule(_ cues: [SoundKeeper.Cue], now: Date) {
        prune(cues, now: now)
        for c in cues where players[c.key] == nil && !started.contains(c.key) {
            guard let made = CountInSound.player(for: c) else { continue }
            let (p, at) = made
            p.volume = SoundBoard.volume(c.cue)
            let delay = at.timeIntervalSince(now)
            // inside its count-in already, the beats that fit were chosen for now: at once (only ever a few ms)
            let ok = delay > 0.02 ? p.play(atTime: p.deviceCurrentTime + delay) : p.play()
            guard ok else { continue }
            players[c.key] = (p, c.playAt, c.zeroAt)
            if delay <= 0.02 { started.insert(c.key) }
        }
        markStarted(now: now)
    }

    /// Stops every zero's sound that's no longer ahead (VirtCore's `SoundKeeper.keeps`): one waiting or counting in
    /// for a zero that was paused, moved or skipped stops; a zero sound already ringing plays out.
    private func prune(_ cues: [SoundKeeper.Cue], now: Date) {
        let wanted = Set(cues.map(\.key))
        for (key, p) in players {
            let sounding = p.playAt <= now && p.player.isPlaying
            if SoundKeeper.keeps(playAt: p.playAt, zeroAt: p.zeroAt, sounding: sounding, wanted: wanted.contains(key), now: now) {
                continue
            }
            p.player.stop()
            players[key] = nil
        }
    }

    /// Zeros whose moment has come are remembered as played (the app then never plays them too).
    private func markStarted(now: Date) {
        for (key, p) in players where p.playAt <= now { started.insert(key) }
        if started.count > 200 { started = Set(started.suffix(100)) }
        // finished ones are let go
        for (key, p) in players where p.playAt < now.addingTimeInterval(-10) && !p.player.isPlaying { players[key] = nil }
    }

    private func cancelUnstarted(now: Date) {
        markStarted(now: now)
        for (key, p) in players where p.playAt > now {
            p.player.stop()
            players[key] = nil
        }
    }

    /// Every scheduled zero again (the output changed, so the device clock may have too).
    private func rescheduleAll(now: Date) {
        cancelUnstarted(now: now)
        onChange?()
    }

    // MARK: - Interruptions and route changes

    private func observe() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self.interrupted(raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))) }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // the keeper's own category change isn't a new output
            guard raw != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
            Task { @MainActor in self.routeChanged() }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.servicesReset() }
        }
    }

    /// A call, Siri or an alarm took the audio: the notifications sound until it ends; then the keeper comes back.
    private func interrupted(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began?:
            guard state == .on else { return }
            cancelUnstarted(now: Date())
            failedAt = Date()
            set(.interrupted)
            onChange?()
        case .ended?:
            guard state == .interrupted else { return }
            set(.off)  // the next update starts it again (if it's still wanted) and schedules the zeros
            onChange?()
        default: break
        }
    }

    /// Headphones in or out, a speaker connected: the silent loop keeps going and the zeros are scheduled again.
    private func routeChanged() {
        guard state == .on else { return }
        if loop?.isPlaying != true, loop?.play() != true {
            failedAt = Date()
            set(.interrupted)
        }
        rescheduleAll(now: Date())
    }

    private func servicesReset() {
        guard state != .off else { return }
        players = [:]
        loop = nil
        sessionHeld = false
        set(.off)
        onChange?()
    }

    // MARK: - Files

    private enum KeeperError: Error { case loopWouldNotPlay }

    /// One second of silence (16-bit mono PCM, 8 kHz), made here so no file ships for it.
    static let silence: Data = {
        let rate: UInt32 = 8000, samples = rate
        let dataBytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }()
}
