import XCTest
@testable import VirtCore

/// The three-second count-in (Tyler, Nov 27, build 95: "I need it to start around 3 seconds not 1 second"): beats at
/// -3, -2 and -1 s and the zero sound on the zero, in every style, locked or open; the edge rules; the one sound it's
/// built as; and the files it's built from (all at the same -1.5 dBFS peak: "The sound could be louder").
final class CountInTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_021_200)
    func s(_ n: TimeInterval) -> Date { t0.addingTimeInterval(n) }

    func board(_ id: String = "rest:0", kind: TimerKind = .rest, from: TimeInterval = 0, ends: TimeInterval,
               upcoming: [Step] = []) -> TimerBoard {
        var b = TimerBoard()
        b.apply(.workoutStart(title: "Legs A"), now: s(from))
        b.apply(.timerStart(TimerStart(id: id, kind: kind, label: "Rest", endsAt: s(ends), startedAt: s(from), next: "set 2",
                                       upcoming: upcoming)), now: s(from))
        return b
    }

    // MARK: - The timing rule

    func testEveryStyleCountsInThreeSecondsAndLandsOnTheZero() {
        let b = board(ends: 60)
        for style in SoundStyle.allCases {
            let c = SoundKeeper.cues(board: b, style: style, now: s(1))
            XCTAssertEqual(c.map(\.beats), [3], style.rawValue)
            XCTAssertEqual(c.map(\.playAt), [s(57)], style.rawValue)
            XCTAssertEqual(c.map(\.zeroAt), [s(60)], style.rawValue)
        }
        XCTAssertEqual(LeadIn.ticks(zero: s(60), now: s(1), length: 60), [s(57), s(58), s(59)])
    }

    func testWorkEndsGetsTheSameCountInAsRestEnds() {
        // a timed work or hold's end, and an interval change: the same 3 s; Chime and Digital keep their two sounds
        let w = board("hold:0", kind: .hold, ends: 40)
        let c = SoundKeeper.cues(board: w, style: .chime, now: s(1))
        XCTAssertEqual(c.map(\.cue), [.rest])
        XCTAssertEqual(c.map(\.file), ["virt-chime-rest.caf"], "work ends: the falling bell, after the 3-2-1")
        XCTAssertEqual(c.map(\.tick), ["virt-chime-tick.caf"])
        XCTAssertEqual(c.map(\.playAt), [s(37)])
        let r = SoundKeeper.cues(board: board(ends: 40), style: .digital, now: s(1))
        XCTAssertEqual(r.map(\.file), [SoundStyle.startFile], "rest ends: the green light, its tones the count-in")
        XCTAssertEqual(r.map(\.tick), [nil])
        XCTAssertEqual(r.map(\.playAt), [s(37)])
    }

    func testAShortCountdownPlaysOnlyTheBeatsThatFit() {
        // 2.5 s: -2 and -1, then the zero (the -3 beat would be before the countdown began)
        XCTAssertEqual(LeadIn.beats(zero: s(2.5), now: s(0), length: 2.5), 2)
        XCTAssertEqual(LeadIn.ticks(zero: s(2.5), now: s(0), length: 2.5), [s(0.5), s(1.5)], "still on whole seconds before the zero")
        // 1.2 s: there's room for no whole beat after its start, so just the zero sound, on time
        XCTAssertEqual(LeadIn.beats(zero: s(1.2), now: s(0), length: 1.2), 0)
        XCTAssertEqual(LeadIn.start(zero: s(1.2), now: s(0), length: 1.2), s(1.2))
        // exactly 3 s: the -3 beat would sit on the countdown's own start, so -2 and -1
        XCTAssertEqual(LeadIn.beats(zero: s(3), now: s(0), length: 3), 2)
        XCTAssertEqual(LeadIn.beats(zero: s(3.25), now: s(0), length: 3.25), 3)
        // never late: a beat with no time to schedule it is skipped, the rest keep their place
        XCTAssertEqual(LeadIn.beats(zero: s(60), now: s(57.99), length: 60), 1, "the -2 beat is 10 ms off: skipped")
        XCTAssertEqual(LeadIn.beats(zero: s(60), now: s(59.99), length: 60), 0)
        XCTAssertEqual(LeadIn.beats(zero: s(60), now: s(61), length: 60), 0)
        let b = board(ends: 2.5)
        XCTAssertEqual(SoundKeeper.cues(board: b, style: .glass, now: s(0)).map(\.playAt), [s(0.5)])
    }

    func testMinus15LeavingUnderThreeSeconds() {
        var b = board(ends: 20)
        b.apply(.minus15, now: s(3))  // 2 s left
        let c = SoundKeeper.cues(board: b, style: .buzzerHorn, now: s(3))
        XCTAssertEqual(c.map(\.zeroAt), [s(5)])
        XCTAssertEqual(c.map(\.beats), [1], "only -1 fits after the -2 beat's moment is too close")
        XCTAssertEqual(c.map(\.playAt), [s(4)])
        var d = board(ends: 30)
        d.apply(.minus15, now: s(10))  // 5 s left: all three
        XCTAssertEqual(SoundKeeper.cues(board: d, style: .buzzerHorn, now: s(10)).map(\.playAt), [s(12)])
    }

    func testAPauseInsideTheCountInStopsItAndResumeTimesItAgain() {
        var b = board(ends: 60)
        let before = SoundKeeper.cues(board: b, style: .chime, now: s(57.5))
        XCTAssertEqual(before.map(\.playAt), [s(58)])
        b.apply(.pause, now: s(58.5))  // inside the count-in: 1.5 s left
        let paused = SoundKeeper.cues(board: b, style: .chime, now: s(58.5))
        XCTAssertTrue(paused.isEmpty)
        // the sound already counting in for that zero stops (it would run on into a zero that isn't there)
        XCTAssertFalse(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: true, wanted: false, now: s(58.5)))
        b.apply(.resume, now: s(70))
        let resumed = SoundKeeper.cues(board: b, style: .chime, now: s(70))
        XCTAssertEqual(resumed.map(\.zeroAt), [s(71.5)])
        XCTAssertEqual(resumed.map(\.beats), [1])
        XCTAssertEqual(resumed.map(\.playAt), [s(70.5)], "on the beat a whole second before the new zero")
        XCTAssertNotEqual(resumed[0].key, before[0].key, "a new zero, so a new sound")
    }

    func testUpcomingStepsEachGetTheirCountInAndCloseZerosDontOverlap() {
        // work to 30, a 2 s switch, work to 62, a 3 s switch, a 15 s switch rest, work
        let b = board("int:0", kind: .work, ends: 30, upcoming: [
            Step(id: "int:1", kind: .intervalRest, label: "Switch", endsAt: s(32)),
            Step(id: "int:2", kind: .work, label: "Work", endsAt: s(62)),
            Step(id: "int:3", kind: .intervalRest, label: "Switch", endsAt: s(65)),
            Step(id: "int:4", kind: .intervalRest, label: "Rest", endsAt: s(80)),
        ])
        let c = SoundKeeper.cues(board: b, style: .marimba, now: s(1))
        XCTAssertEqual(c.map(\.zeroAt), [s(30), s(32), s(62), s(65), s(80)])
        XCTAssertEqual(c.map(\.beats), [3, 1, 3, 2, 3])
        XCTAssertEqual(c.map(\.playAt), [s(27), s(31), s(59), s(63), s(77)])
        for i in 1..<c.count {
            XCTAssertGreaterThan(c[i].playAt, c[i - 1].zeroAt, "a count-in starts after the zero before it")
        }
    }

    func testAFifteenSecondSwitchRestIsMostlyCountIn() {
        // accepted (Nov 27): 3 of a 15 s rest's seconds are its count-in
        let b = board(ends: 15)
        XCTAssertEqual(SoundKeeper.cues(board: b, style: .chime, now: s(0)).map(\.playAt), [s(12)])
    }

    func testKeepOrStop() {
        // the same zero still ahead: kept, waiting or counting in (a refresh never restarts or cuts it)
        XCTAssertTrue(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: false, wanted: true, now: s(10)))
        XCTAssertTrue(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: true, wanted: true, now: s(58)))
        // gone (paused, moved, skipped, Sounds off): waiting or counting in, it stops
        XCTAssertFalse(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: false, wanted: false, now: s(10)))
        XCTAssertFalse(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: true, wanted: false, now: s(59)))
        // its zero has come: the zero sound rings out
        XCTAssertTrue(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: true, wanted: false, now: s(60.3)))
        // done playing: let go
        XCTAssertFalse(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: false, wanted: false, now: s(62)))
    }

    func testSoundsOffIsSilence() {
        let b = board(ends: 60)
        XCTAssertFalse(SoundKeeper.shouldRun(soundsOn: false, away: true, board: b, live: true, now: s(58)))
        // Engine hands the keeper no zeros with Sounds off, so one counting in stops
        XCTAssertFalse(SoundKeeper.keeps(playAt: s(57), zeroAt: s(60), sounding: true, wanted: false, now: s(58)))
    }

    // MARK: - One sound per zero

    func testComposeAndSlice() {
        let rate = 4
        let tick: [Float] = [0.5, 0.25]
        let zero: [Float] = [0.8, 0.4]
        let w = LeadIn.compose(tick: tick, zero: zero, rate: rate)
        XCTAssertEqual(w.count, 3 * rate + zero.count)
        for k in 0..<3 {
            XCTAssertEqual(w[k * rate], 0.5 * LeadIn.tickVolume, accuracy: 1e-6, "a beat at \(k) s")
            XCTAssertEqual(w[k * rate + 1], 0.25 * LeadIn.tickVolume, accuracy: 1e-6)
            XCTAssertEqual(w[k * rate + 2], 0)
        }
        XCTAssertEqual(Array(w[12...]), zero, "the zero sound at exactly 3 s")
        XCTAssertEqual(LeadIn.slice(w, rate: rate, beats: 3), w)
        XCTAssertEqual(LeadIn.slice(w, rate: rate, beats: 2), Array(w[4...]), "starts on the -2 beat")
        XCTAssertEqual(LeadIn.slice(w, rate: rate, beats: 0), zero, "just the zero sound")
        XCTAssertEqual(LeadIn.slice(w, rate: rate, beats: 9), w)
        XCTAssertEqual(LeadIn.compose(tick: nil, zero: zero, rate: rate), zero, "the green light is its own count-in")
        // a tick longer than a second is cut at the next beat; nothing clips
        let long = LeadIn.compose(tick: [Float](repeating: 1, count: 9), zero: [1], rate: rate, tickVolume: 2)
        XCTAssertEqual(long.count, 13)
        XCTAssertEqual(long.max(), 1)
    }

    func testWav() {
        let d = LeadIn.wav([0, 1, -1, 0.5], rate: 44100)
        XCTAssertEqual(d.count, 44 + 8)
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        let rate = d[24..<28].enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        XCTAssertEqual(rate, 44100)
        let pcm = stride(from: 44, to: 52, by: 2).map { Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8) }
        XCTAssertEqual(pcm, [0, 32767, -32767, 16384])
    }

    // MARK: - The files

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// A bundled 16-bit mono .caf (as scripts/sounds.py writes them): its rate and samples.
    func caf(_ name: String) throws -> (rate: Double, samples: [Float]) {
        let d = try Data(contentsOf: Self.root.appendingPathComponent("App/Sounds/\(name)"))
        let b = [UInt8](d)
        func be64(_ i: Int) -> Int { (0..<8).reduce(0) { ($0 << 8) | Int(b[i + $1]) } }
        func be32(_ i: Int) -> UInt32 { (0..<4).reduce(0) { ($0 << 8) | UInt32(b[i + $1]) } }
        XCTAssertEqual(String(decoding: b[0..<4], as: UTF8.self), "caff", name)
        var i = 8, rate = 0.0, little = true, samples: [Float] = []
        while i + 12 <= b.count {
            let kind = String(decoding: b[i..<(i + 4)], as: UTF8.self), size = be64(i + 4), body = i + 12
            if kind == "desc" {
                rate = Double(bitPattern: (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(b[body + $1]) })
                XCTAssertEqual(String(decoding: b[(body + 8)..<(body + 12)], as: UTF8.self), "lpcm", name)
                little = be32(body + 12) & 2 != 0
                XCTAssertEqual(be32(body + 24), 1, "\(name): mono")
                XCTAssertEqual(be32(body + 28), 16, "\(name): 16-bit")
            } else if kind == "data" {
                samples = stride(from: body + 4, to: body + size - 1, by: 2).map { j in
                    let v = little ? UInt16(b[j]) | UInt16(b[j + 1]) << 8 : UInt16(b[j]) << 8 | UInt16(b[j + 1])
                    return Float(Int16(bitPattern: v)) / 32768
                }
            }
            i = body + size
        }
        return (rate, samples)
    }

    func testEveryCountInIsBuiltFromFilesOfOneRate() throws {
        for style in SoundStyle.allCases {
            for cue in [SoundCue.go, .rest] {
                let files = [style.file(cue)] + (style.countInTick(cue).map { [$0] } ?? [])
                for f in files where f.hasSuffix(".caf") {
                    XCTAssertEqual(try caf(f).rate, 44100, "\(style.rawValue): \(f)")
                }
            }
        }
    }

    func testTheGreenLightIsThreeTonesASecondApartThenGo() throws {
        let g = try caf(SoundStyle.startFile)
        let rate = Int(g.rate)
        XCTAssertGreaterThan(g.samples.count, 3 * rate)
        // each of its four tones starts on a whole second, with silence between
        for k in 0...3 {
            let at = k * rate
            XCTAssertGreaterThan(g.samples[at..<(at + rate / 50)].map(abs).max() ?? 0, 0.1, "a tone at \(k) s")
            if k > 0 {
                XCTAssertEqual(g.samples[(at - rate / 2)..<(at - 1)].map(abs).max() ?? 1, 0, accuracy: 1e-4, "quiet before \(k) s")
            }
        }
        // the first green light stays in the app, untouched, for a rollback
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("App/Sounds/\(SoundStyle.firstStartFile)").path))
    }

    func peak(_ n: String) throws -> Double { 20 * log10(Double(try caf(n).samples.map(abs).max() ?? 0)) }

    /// Nov 27: louder by one gain per style. The tone styles and the green light at -1.5 dBFS peak; Chime and Digital
    /// each +5.5 dB on every file, so their loudest zero is at -1.5 and the ticks and clicks stay as far under it as
    /// Tyler approved.
    func testLevelsAndTheBalanceInsideEachStyle() throws {
        for s in SoundStyle.allCases where s.isTone { XCTAssertEqual(try peak(s.file(.go)), -1.5, accuracy: 0.05, s.rawValue) }
        XCTAssertEqual(try peak(SoundStyle.startFile), -1.5, accuracy: 0.05)
        // (file, peak before Nov 27): each now exactly 5.5 dB up
        let before: [(String, Double)] = [
            ("virt-chime-go.caf", -7.0), ("virt-chime-rest.caf", -7.0), ("virt-chime-finish.caf", -9.0),
            ("virt-chime-tick.caf", -22.9), ("virt-chime-set.caf", -29.94),
            ("virt-digital-go.caf", -7.6), ("virt-digital-rest.caf", -7.0), ("virt-digital-finish.caf", -9.33),
            ("virt-digital-tick.caf", -29.0), ("virt-digital-set.caf", -35.25),
        ]
        for (n, p) in before { XCTAssertEqual(try peak(n), p + 5.5, accuracy: 0.06, n) }
        // the count-in's beats: 10 to 12 dB under a tone style's zero
        let beat = try peak("virt-chime-tick.caf") + 20 * log10(Double(LeadIn.tickVolume))
        XCTAssertEqual(beat - (-1.5), -11, accuracy: 1)
    }
}
