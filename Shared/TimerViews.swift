import AppIntents
import SwiftUI
import VirtCore

// The Live Activity's views, compiled into both the timer extension and the app (the test build's widget gallery
// draws them at real size for the screenshots).

func symbol(_ k: TimerKind) -> String {
    switch k {
    case .rest: return "hourglass"
    case .hold: return "figure.core.training"
    case .work: return "flame.fill"
    case .intervalRest: return "wind"
    case .other: return "timer"
    }
}

struct LockScreenTimer: View {
    let title: String
    let d: TimerDisplay
    /// Dimmed (StandBy at night, the always-on screen): the clock alone, as big as it goes.
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        if d.betweenSets == true { BetweenSets(title: title, d: d, dimmed: dimmed) } else if dimmed { dimmedBody } else { fullBody }
    }

    /// StandBy scales this whole view up to fill the screen, so the clock gets most of the room.
    private var dimmedBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Label(d.label, systemImage: symbol(d.kind)).font(.headline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Spacer(minLength: 4)
                ClockText(d: d).font(.system(size: 58, weight: .bold, design: .rounded)).foregroundStyle(Color.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            // its own row, the card's whole width: beside the clock it was cut off ("Next: set 3 of 4 · 105…")
            NextLine(d: d)
        }
        .padding(16)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        // with a set to log next, its exercise takes the day's place (the next line says which set)
                        Text((d.setExercise ?? title).uppercased()).font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.65)).lineLimit(1)
                        Label(d.label, systemImage: symbol(d.kind)).font(.headline).foregroundStyle(.white).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    ClockText(d: d).font(.system(size: 46, weight: .bold, design: .rounded)).foregroundStyle(Color.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                // its own row under the clock, the card's whole width: squeezed beside the clock it was cut off
                // ("Next: set 3 of 4 · 105…") and the clock shrank too. The tighter padding keeps the card inside the
                // lock screen's 160-point limit.
                NextLine(d: d)
            }
            Bar(d: d)
            Buttons(d: d).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The countdown (or a stopwatch counting up), drawn by the system so it keeps time with the app asleep.
struct ClockText: View {
    let d: TimerDisplay

    var body: some View {
        Group {
            if let from = d.countsUpFrom {
                if d.paused { Text(TimerDisplay.clock(d.elapsed ?? 0)) } else { Text(from, style: .timer) }
            } else if let end = d.endsAt {
                Text(timerInterval: min(d.progressFrom ?? end, end)...end, countsDown: true, showsHours: false)
            } else {
                Text(TimerDisplay.clock(d.remaining ?? 0))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

struct Bar: View {
    let d: TimerDisplay

    var body: some View {
        Group {
            if let end = d.endsAt, let from = d.progressFrom, from < end {
                ProgressView(timerInterval: from...end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else if let f = d.fraction {
                ProgressView(value: f)
            } else {
                ProgressView(value: d.countsUpFrom == nil ? 1 : 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(.virtAccent)
    }
}

/// Between sets (no timer running): the next set, and a big Log set (#573).
struct BetweenSets: View {
    let title: String
    let d: TimerDisplay
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.white.opacity(0.65))
                Label(d.setExercise ?? d.label, systemImage: "dumbbell.fill").font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(d.setDetail ?? "").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            if let words = d.logButton, !dimmed { LogButton(words: words, big: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// Log set: logs the next set on the page, and starts its rest (the same path as the timer buttons).
struct LogButton: View {
    let words: String
    var big = false

    var body: some View {
        Button(intent: TimerCommandIntent(.log)) {
            Label(big ? words : "Log", systemImage: "checkmark")
                .font((big ? Font.title3 : Font.body).weight(.semibold))
                .frame(maxWidth: big ? .infinity : nil)
                .foregroundStyle(Color.virtBlack)
        }
        .buttonStyle(.borderedProminent)
        .tint(.virtAccent)
        .accessibilityLabel(words)
    }
}

struct NextLine: View {
    let d: TimerDisplay
    /// The whole next set ("Chest press machine · set 3 of 4 · 105 × 10"), where the exercise isn't shown above it.
    var full = false

    var nextWords: String {
        if let n = full ? d.nextSet : d.setDetail { return "Next: \(n)" }
        return d.next.isEmpty || d.next == "Done" ? (d.next == "Done" ? "Last one" : " ") : "Next: \(d.next)"
    }

    /// The Dynamic Island's whole next set, split after the exercise when it's too wide for one line.
    private var split: (exercise: String, detail: String)? {
        guard full, let ex = d.setExercise, let detail = d.setDetail, d.nextSet == "\(ex) · \(detail)" else { return nil }
        return (ex, detail)
    }

    var body: some View {
        Group {
            if let split {
                // one line where it fits; otherwise "Next: Chest press machine", then "set 3 of 4 · 105 × 10" under it
                ViewThatFits(in: .horizontal) {
                    row(nextWords)
                    VStack(spacing: 1) {
                        row("Next: \(split.exercise)")
                        Text(split.detail).foregroundStyle(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
            } else {
                row(nextWords)
            }
        }
        .font(.subheadline)
    }

    private func row(_ words: String) -> some View {
        HStack(spacing: 4) {
            if d.paused { Text("Paused ·").foregroundStyle(Color.virtAccent) }
            Text(words)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(full ? 1 : 0.85)
            if let n = d.nextEndsAt, let end = d.endsAt, end < n {
                Text(timerInterval: end...n, countsDown: true, showsHours: false).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// −15, pause or resume, +15, and skip (Stop for a stopwatch hold); Log set when there's a set to log.
struct Buttons: View {
    let d: TimerDisplay

    var body: some View {
        HStack(spacing: 10) {
            if d.countsUpFrom == nil {
                Button(intent: TimerCommandIntent(.minus15)) { Image(systemName: "gobackward.15") }
            }
            Button(intent: TimerCommandIntent(d.paused ? .resume : .pause)) { Image(systemName: d.paused ? "play.fill" : "pause.fill") }
            if d.countsUpFrom == nil {
                Button(intent: TimerCommandIntent(.add15)) { Image(systemName: "goforward.15") }
            }
            Button(intent: TimerCommandIntent(.skip)) { Image(systemName: d.countsUpFrom == nil ? "forward.end.fill" : "stop.fill") }
            // at the rest's zero the app may be asleep, so Log set stays on the timer too (#573)
            if let words = d.logButton { LogButton(words: words) }
        }
        .buttonStyle(.bordered)
        .tint(.virtAccent)
        .font(.body.weight(.semibold))
    }
}
