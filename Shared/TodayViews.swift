import SwiftUI
import WidgetKit
import VirtCore

// The Today and Week widgets' views, compiled into both the widget extension and the app (the test build's widget
// gallery draws them at real size). They show only what's needed: the day's name, done or not, the week's count and
// the streak. Never weights, sets or notes. The day's name is marked private, so a locked phone can hide it.

/// The week ring: weekDone of weekPlanned, gold on a dim track.
struct WeekRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(Color.virtGold.opacity(0.22), lineWidth: lineWidth)
            if fraction > 0 {
                Circle().trim(from: 0, to: min(1, fraction))
                    .stroke(Color.virtGold, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// The ring with the week's count in the middle.
struct WeekCount: View {
    let s: TodayStatus
    var size: CGFloat
    var lineWidth: CGFloat
    var showOf = true

    var body: some View {
        ZStack {
            WeekRing(fraction: s.ring, lineWidth: lineWidth).widgetAccentable()
            VStack(spacing: -2) {
                Text("\(s.weekDone)").font(.system(size: size * 0.32, weight: .bold, design: .rounded)).foregroundStyle(.white)
                if showOf {
                    Text("of \(s.weekPlanned)").font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.weekLine)
    }
}

// MARK: - Home Screen

/// Small: today's name, done or not, and the week. `standBy` (StandBy, where the background goes) makes the week's
/// count the big thing, readable from across the room.
struct TodaySmall: View {
    let s: TodayStatus
    var standBy = false

    var body: some View {
        if standBy {
            VStack(spacing: 6) {
                WeekCount(s: s, size: 104, lineWidth: 11)
                Text(s.done ? "Done today" : s.title).font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(s.done ? Color.virtGold : .white).lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(s.caption).font(.caption2.weight(.bold)).foregroundStyle(Color.virtGold).kerning(0.6)
                    Spacer(minLength: 0)
                    if s.done { Image(systemName: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Color.virtGold) }
                }
                Text(s.title).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.75).privacySensitive()
                Text(s.statusLine).font(.footnote).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                HStack(spacing: 8) {
                    WeekCount(s: s, size: 38, lineWidth: 4.5, showOf: false)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(s.weekDone) of \(s.weekPlanned)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        Text(s.streakLine ?? "this week").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Medium: the week's ring on the left; today, the streak and the next workout on the right.
struct TodayMedium: View {
    let s: TodayStatus
    var standBy = false

    var body: some View {
        HStack(spacing: 16) {
            WeekCount(s: s, size: standBy ? 128 : 112, lineWidth: standBy ? 12 : 10)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(s.caption).font(.caption2.weight(.bold)).foregroundStyle(Color.virtGold).kerning(0.6)
                    if s.done { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.virtGold) }
                }
                Text(s.title).font(.system(size: standBy ? 26 : 22, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.7).privacySensitive()
                Text(s.statusLine).font(.subheadline).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                Spacer(minLength: 2)
                if let streak = s.streakLine {
                    Label(streak, systemImage: "flame.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.virtGold)
                        .labelStyle(.titleAndIcon).lineLimit(1)
                }
                if let n = s.next, n.inDays > 0 {
                    Text("Next: \(TodayStatus.dayName(n, short: false))" + (n.time.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                } else {
                    Text(s.weekLine).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lock Screen

/// Circular: the week ring with the count.
struct WeekCircular: View {
    let s: TodayStatus

    var body: some View {
        Gauge(value: Double(min(s.weekDone, max(1, s.weekPlanned))), in: 0...Double(max(1, s.weekPlanned))) {
            Image(systemName: "figure.strengthtraining.traditional")
        } currentValueLabel: {
            Text("\(s.weekDone)/\(s.weekPlanned)").font(.system(size: 17, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .accessibilityLabel(s.weekLine)
    }
}

/// Circular: the next workout's day and time (a check once today's is done and nothing's left this week).
struct NextCircular: View {
    let s: TodayStatus
    /// The system's round backing (AccessoryWidgetBackground) in a real widget; the gallery draws its own.
    var background: AnyView

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                if let n = s.next {
                    Text(n.inDays == 0 ? "TODAY" : TodayStatus.dayName(n, short: true).uppercased())
                        .font(.system(size: 10, weight: .bold)).widgetAccentable()
                    Text(shortTime(n.time) ?? (n.inDays == 0 ? "Go" : "Train"))
                        .font(.system(size: 18, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                } else {
                    Image(systemName: s.done ? "checkmark" : "figure.strengthtraining.traditional").font(.title3.weight(.semibold))
                }
            }
            .padding(6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(s.nextLines.caption.lowercased()), \(s.nextLines.title)")
    }

    /// "6:30 PM" -> "6:30" (the circle has no room for PM).
    func shortTime(_ t: String?) -> String? { t.map { $0.replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") } }
}

/// Rectangular: the next workout.
struct NextRectangular: View {
    let s: TodayStatus

    var body: some View {
        let l = s.nextLines
        VStack(alignment: .leading, spacing: 0) {
            Text(l.caption).font(.system(size: 11, weight: .bold)).kerning(0.4).widgetAccentable().lineLimit(1)
            Text(l.title).font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                .privacySensitive()
            Text(l.detail).font(.system(size: 13)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rectangular: the week ring, the count and the streak.
struct WeekRectangular: View {
    let s: TodayStatus

    var body: some View {
        HStack(spacing: 8) {
            Gauge(value: Double(min(s.weekDone, max(1, s.weekPlanned))), in: 0...Double(max(1, s.weekPlanned))) {
                EmptyView()
            } currentValueLabel: {
                Text("\(s.weekDone)").font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 0) {
                Text("THIS WEEK").font(.system(size: 11, weight: .bold)).kerning(0.4).widgetAccentable()
                Text("\(s.weekDone) of \(s.weekPlanned) done").font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(s.streakLine ?? (s.done ? "Done today" : s.day == .rest ? "Rest day" : s.title)).font(.system(size: 13))
                    .opacity(0.8).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline, above the Lock Screen's clock.
struct TodayInline: View {
    let s: TodayStatus

    var body: some View {
        Label(s.inlineLine, systemImage: s.done ? "checkmark.circle" : "figure.strengthtraining.traditional")
    }
}
