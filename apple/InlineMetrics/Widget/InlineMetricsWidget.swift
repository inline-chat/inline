import SwiftUI
import WidgetKit

private struct MetricsEntry: TimelineEntry {
  let date: Date
  let snapshot: MetricsSnapshot
}

private struct MetricsProvider: TimelineProvider {
  func placeholder(in context: Context) -> MetricsEntry {
    MetricsEntry(date: Date(), snapshot: .sample)
  }

  func getSnapshot(in context: Context, completion: @escaping (MetricsEntry) -> Void) {
    completion(MetricsEntry(date: Date(), snapshot: context.isPreview ? .sample : read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
    let now = Date()
    let snapshot = read()
    // Include future entries so stale/expired data is labelled even if reloads are delayed.
    var dates = [now]
    if let fetchedAt = snapshot.fetchedAt {
      let staleAt = fetchedAt.addingTimeInterval(MetricsSnapshot.staleAfter)
      if staleAt > now { dates.append(staleAt) }
    }
    if let expires = snapshot.sessionExpiresAt, expires > now { dates.append(expires) }
    let entries = dates.sorted().map { MetricsEntry(date: $0, snapshot: snapshot) }
    completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(MetricsSnapshot.widgetRefreshInterval))))
  }

  private func read() -> MetricsSnapshot { (try? SnapshotStore.shared().read()) ?? .signedOut }
}

private struct WidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: MetricsEntry

  var body: some View {
    MetricsCard(snapshot: entry.snapshot, size: size, now: entry.date)
      .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
      .widgetURL(URL(string: "inline-metrics://refresh"))
      .privacySensitive()
  }

  private var size: MetricsCard.Size {
    switch family {
    case .systemSmall: .small
    case .systemLarge: .large
    default: .medium
    }
  }
}

@main
struct InlineMetricsWidget: Widget {
  let kind = "InlineMetricsWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: MetricsProvider()) { entry in WidgetView(entry: entry) }
      .configurationDisplayName("Inline Metrics")
      .description("Active users, messages and growth at a glance. Keep Inline Metrics running in the menu bar to update.")
      .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
