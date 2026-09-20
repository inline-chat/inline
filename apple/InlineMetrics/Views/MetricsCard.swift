import Charts
import SwiftUI

struct MetricsCard: View {
  enum Size { case small, medium, large }
  let snapshot: MetricsSnapshot
  let size: Size
  var now = Date()
  var isPreview = false

  private let accent = Color(red: 0.20, green: 0.43, blue: 0.95)

  var body: some View {
    VStack(alignment: .leading, spacing: size == .large ? 12 : 6) {
      HStack(spacing: 6) {
        Image(systemName: "chart.xyaxis.line").foregroundStyle(accent)
        Text("Inline").font(.system(.subheadline, design: .rounded, weight: .semibold))
        Spacer()
        Text(isPreview ? "SAMPLE" : "UTC")
          .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
      }

      if let metrics = snapshot.visibleMetrics(at: now) {
        if size == .small {
          metric("Active today", value: metrics.dau, change: metrics.activeUsersChange, prominent: true)
          Spacer(minLength: 0)
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(metrics.messagesToday, format: .number.notation(.compactName)).fontWeight(.semibold)
            Text("messages").foregroundStyle(.secondary)
          }.font(.caption)
        } else {
          LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading, spacing: size == .large ? 12 : 6) {
            metric("Active today", value: metrics.dau, change: metrics.activeUsersChange)
            metric("Active this week", value: metrics.wau)
            metric("Messages today", value: metrics.messagesToday, change: metrics.messagesChange)
            metric("On the waitlist", value: metrics.waitlistCount)
            if size == .large {
              metric("New users today", value: metrics.newUsersLastDay, change: metrics.newUsersChange)
              metric("New waitlist today", value: metrics.newWaitlistLastDay)
            }
          }
          if size == .large {
            let chartDays = metrics.chartDays
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("DAILY ACTIVE USERS")
                Spacer()
                Text("Changes vs yesterday")
              }.font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
              Chart(chartDays) { day in
                BarMark(x: .value("Day (UTC)", day.date, unit: .day), y: .value("Active users", day.activity.activeUsers))
                  .foregroundStyle(accent.gradient).cornerRadius(3)
                  .accessibilityLabel("\(day.label), \(day.activity.activeUsers) active users")
              }
              .environment(\.timeZone, MetricsDate.calendar.timeZone)
              .environment(\.calendar, MetricsDate.calendar)
              .chartXAxis(.hidden)
              .chartYAxis(.hidden)
              .chartYScale(domain: 0...max(1, chartDays.map(\.activity.activeUsers).max() ?? 1))
              .frame(maxHeight: .infinity)
              HStack {
                Text(chartDays.first?.label ?? "")
                Spacer()
                Text(chartDays.last?.label ?? "")
              }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 4) {
          Circle().fill(snapshot.status(at: now) == "Updated" ? Color.green : Color.orange).frame(width: 4, height: 4)
          if snapshot.status(at: now) == "Updated", let date = metrics.reportedAt {
            Text(date, style: .time)
          } else {
            Text(snapshot.status(at: now)).lineLimit(1).minimumScaleFactor(0.8)
          }
          Spacer(minLength: 0)
          if size != .small {
            Link(destination: URL(string: "inline-metrics://refresh")!) {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh metrics")
            .help("Open Inline Metrics and check for new data")
          }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .accessibilityLabel("\(snapshot.status(at: now)). Last updated \(metrics.reportedAt?.formatted() ?? "unknown")")
      } else {
        Spacer(minLength: 0)
        Image(systemName: snapshot.state == .unavailable ? "wifi.exclamationmark" : "lock.fill")
          .font(.title2).foregroundStyle(accent)
        Text(snapshot.state == .unavailable ? "Metrics unavailable" : snapshot.status(at: now))
          .font(.headline)
        Text("Open Inline Metrics")
          .font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
  }

  private func metric(_ title: String, value: Int, change: MetricChange? = nil, prominent: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(value, format: .number.notation(.compactName))
          .font(.system(size: prominent ? 34 : 22, weight: .semibold, design: .rounded))
          .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        if let change {
          HStack(spacing: 2) {
            if change.direction != 0 {
              Image(systemName: change.direction < 0 ? "arrow.down.right" : "arrow.up.right")
            }
            Text(change.text)
          }
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(change.direction < 0 ? Color.red : (change.direction > 0 ? Color.green : Color.secondary))
          .lineLimit(1).minimumScaleFactor(0.75)
          .help(change.explanation)
        }
      }
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(value). \(change?.explanation ?? "")")
  }
}
