import SwiftUI
import VirtCore
import WidgetKit

/// One moment of the Today and Week widgets.
struct TodayEntry: TimelineEntry {
    let date: Date
    let status: TodayStatus
}

/// Reads the last `today` the page sent (SharedStore) and works out what to show now and at midnight, when the day
/// turns over by itself. The app asks for a fresh timeline whenever the page sends a new `today`.
struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: Date(), status: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let now = Date()
        completion(TodayEntry(date: now, status: context.isPreview ? .sample : SharedStore.loadToday().status(now: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let info = SharedStore.loadToday()
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let entries = [TodayEntry(date: now, status: info.status(now: now)),
                       TodayEntry(date: midnight, status: info.status(now: midnight.addingTimeInterval(1)))]
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }
}

/// The Today widget: Home Screen small and medium, and the Lock Screen's "next workout" (circular, rectangular,
/// inline). A tap opens Virt to today.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "virt.today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.virtBlack }
                .widgetURL(AppLink.today.url)
        }
        .configurationDisplayName("Today")
        .description("Today's workout or rest day, done or not, and your week.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family
    /// False in StandBy, where the system takes the background away: the big-number layout then.
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        switch family {
        case .systemMedium: TodayMedium(s: entry.status, standBy: !showsBackground)
        case .accessoryCircular: NextCircular(s: entry.status, background: AnyView(AccessoryWidgetBackground()))
        case .accessoryRectangular: NextRectangular(s: entry.status)
        case .accessoryInline: TodayInline(s: entry.status)
        default: TodaySmall(s: entry.status, standBy: !showsBackground)
        }
    }
}

/// The Week widget, for the Lock Screen: the week ring (circular), or the ring with the count and streak
/// (rectangular).
struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "virt.week", provider: TodayProvider()) { entry in
            WeekWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.virtBlack }
                .widgetURL(AppLink.today.url)
        }
        .configurationDisplayName("This week")
        .description("Workouts done this week, of the ones planned, and your streak.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct WeekWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular { WeekRectangular(s: entry.status) } else { WeekCircular(s: entry.status) }
    }
}
