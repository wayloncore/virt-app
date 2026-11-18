import SwiftUI

/// The intro on a fresh launch (Tyler's idea, Nov 17): the launch screen's gold V moves left as "VIRT" forms around
/// it, the I, R and T fade, and the V glides back to the center, settling exactly where the lock screen's V sits.
/// About 1.2 seconds. Face ID asks while it plays, so it adds no waiting; a tap skips it; with Reduce Motion it's a
/// plain cross-fade. It only ever plays on a fresh launch (AppLock).
///
/// The V is the app's own mark (the same image as the launch and lock screens, so the hand-off is seamless). The I,
/// R and T are vector paths drawn in the mark's style: a thin capped stroke above a thick one, 12 units apart, with
/// the V's slant on every cut end.
struct IntroView: View {
    /// The lock screen's V: 120 points square, centered.
    static let markSize: CGFloat = 120
    static let length: TimeInterval = 1.2

    /// Seconds into the intro to hold still at (the test build's frames); nil plays it.
    var frozenAt: TimeInterval?
    var reduceMotion: Bool
    var start: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: frozenAt != nil)) { context in
            let t = frozenAt ?? context.date.timeIntervalSince(start)
            frame(at: t)
        }
    }

    /// The whole word, in the mark's units (the 360-unit square the V's image is drawn in): the V's image box is
    /// 0...360, and its gold runs from 34 to 325. The letters follow, 30 units apart.
    static let letters: [(name: String, x: CGFloat)] = [("I", 355), ("R", 471), ("T", 681)]
    static let wordLeft: CGFloat = 34, wordRight: CGFloat = 857
    /// Points per unit at the lock screen's size.
    static let unit = markSize / 360
    /// Where the V's box sits (from center) while the word is up, so the whole word is centered.
    static let wordOffset = -((wordLeft + wordRight) / 2 - 180) * unit

    @ViewBuilder
    func frame(at t: TimeInterval) -> some View {
        let p = Self.phase(at: t, reduceMotion: reduceMotion)
        ZStack {
            // the word, with its V
            ZStack {
                ForEach(Self.letters, id: \.name) { l in
                    LetterShape(letter: l.name)
                        .fill(Self.gold)
                        .overlay(LetterShape(letter: l.name).stroke(Self.edge, lineWidth: 0.6))
                        .frame(width: Self.markSize, height: Self.markSize)
                        .offset(x: (l.x - 0) * Self.unit)
                        .opacity(p.letters)
                }
                Image("VirtMark").resizable().scaledToFit().frame(width: Self.markSize, height: Self.markSize)
                    .opacity(p.wordV)
            }
            .offset(x: p.vOffset)
            // the centered V (the launch screen's and the lock screen's); in motion it's the same V as above
            Image("VirtMark").resizable().scaledToFit().frame(width: Self.markSize, height: Self.markSize)
                .opacity(p.centerV)
        }
        .accessibilityHidden(true)
    }

    struct Phase: Equatable {
        var vOffset: CGFloat
        var letters: Double
        var wordV: Double
        var centerV: Double
    }

    static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    /// The intro at `t` seconds. Moving: the V slides left (0 to 0.3 s) as the letters fade in, holds, the letters
    /// fade (0.6 to 0.85 s), and the V glides back (0.75 to 1.2 s). Reduce Motion: the centered V and the word
    /// cross-fade in place.
    static func phase(at t: TimeInterval, reduceMotion: Bool) -> Phase {
        if reduceMotion {
            let into = ease(t / 0.3) - ease((t - 0.75) / 0.3)
            return Phase(vOffset: wordOffset, letters: into, wordV: into, centerV: 1 - into)
        }
        let out = ease(t / 0.3) * (1 - ease((t - 0.75) / 0.45))
        let letters = ease((t - 0.05) / 0.25) * (1 - ease((t - 0.6) / 0.25))
        return Phase(vOffset: wordOffset * out, letters: letters, wordV: 1, centerV: 0)
    }

    static let gold = LinearGradient(colors: [Color(red: 0.95, green: 0.84, blue: 0.67), Color(red: 0.91, green: 0.79, blue: 0.62),
                                              Color(red: 0.85, green: 0.73, blue: 0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let edge = Color(red: 0.55, green: 0.45, blue: 0.31).opacity(0.55)
}

/// One letter of the wordmark, as polygons in the mark's 360-unit square (each letter drawn from its own left edge
/// at 0; the view offsets it into place). Heights match the V: the thin capped strokes run from 69 to 98, the thick
/// strokes from 110 to 300, and every cut end leans like the V's arms (16 across for 29 down).
struct LetterShape: Shape {
    let letter: String

    static let polygons: [String: [[CGPoint]]] = {
        func p(_ pts: [(CGFloat, CGFloat)]) -> [CGPoint] { pts.map { CGPoint(x: $0.0, y: $0.1) } }
        return [
            // I: a cap, the stem, a foot
            "I": [p([(0, 69), (86, 69), (70, 98), (16, 98)]),
                  p([(22, 110), (64, 110), (64, 259), (22, 259)]),
                  p([(16, 271), (70, 271), (86, 300), (0, 300)])],
            // R: the stem; the cap running into an angular bowl; the leg at the V's slant
            "R": [p([(0, 110), (42, 110), (42, 300), (0, 300)]),
                  p([(0, 69), (130, 69), (176, 145), (130, 221), (54, 221), (54, 192), (114, 192), (143, 145), (114, 98), (16, 98)]),
                  p([(92, 233), (134, 233), (180, 300), (138, 300)])],
            // T: a wide cap over the stem
            "T": [p([(0, 69), (176, 69), (160, 98), (16, 98)]),
                  p([(67, 110), (109, 110), (109, 300), (67, 300)])],
        ]
    }()

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 360
        var path = Path()
        for poly in Self.polygons[letter] ?? [] {
            path.addLines(poly.map { CGPoint(x: rect.minX + $0.x * s, y: rect.minY + $0.y * s) })
            path.closeSubpath()
        }
        return path
    }
}
