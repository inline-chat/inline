import Foundation
import InlineKit
import SwiftUI
import UIKit

// Shared pieces of the chat info resource tabs (media, files, voice, links): month
// sections memoized per page of rows, one-shot pagination, cached formatters, and the
// inset grouped row chrome. Everything here runs on the main actor and is sized for
// thousands of rows; nothing reads the disk or database.

// MARK: - Sections

/// A month of resources, newest first. Months read as headers above the rows
/// rather than pinned badges, so they never compete with the pinned tab bar.
struct ChatInfoResourceSection<Item>: Identifiable {
  /// `year * 100 + month`, stable across pages.
  let id: Int
  let title: String
  let items: [Item]
}

/// Groups rows into month sections once per distinct page of rows.
///
/// `ChatResourceWindow` republishes `rows` as a new array only when they change, and
/// `Array ==` short-circuits on shared storage, so re-rendering with the same page
/// costs one pointer compare instead of a regroup.
@MainActor
final class ChatInfoResourceSectionCache<Row: Equatable, Item> {
  private var rows: [Row] = []
  private var hasValue = false
  private(set) var sections: [ChatInfoResourceSection<Item>] = []
  /// Every item in display order, for pagination and prefetching by position.
  private(set) var items: [Item] = []

  func sections(
    for rows: [Row],
    date: (Row) -> Date,
    id: (Row) -> Int64,
    makeItem: (Row, ChatInfoResourcePlacement) -> Item
  ) -> [ChatInfoResourceSection<Item>] {
    if hasValue, rows == self.rows { return sections }
    self.rows = rows
    hasValue = true
    sections = ChatInfoResourceMonthGrouping.sections(rows: rows, date: date, id: id, makeItem: makeItem)
    items = sections.flatMap(\.items)
    return sections
  }
}

enum ChatInfoResourceMonthGrouping {
  /// Months newest first; inside a month, newest first with the message id breaking
  /// ties, matching the day groups the view models publish.
  @MainActor
  static func sections<Row, Item>(
    rows: [Row],
    date: (Row) -> Date,
    id: (Row) -> Int64,
    makeItem: (Row, ChatInfoResourcePlacement) -> Item
  ) -> [ChatInfoResourceSection<Item>] {
    guard !rows.isEmpty else { return [] }
    let calendar = ChatInfoResourceFormat.calendar
    var buckets: [Int: [Row]] = [:]
    var month: (key: Int, start: Date, end: Date)?

    // Rows arrive close to date order, so the calendar runs once per month boundary.
    for row in rows {
      let rowDate = date(row)
      if let current = month, rowDate >= current.start, rowDate < current.end {
        buckets[current.key, default: []].append(row)
        continue
      }
      let components = calendar.dateComponents([.year, .month], from: rowDate)
      let key = (components.year ?? 0) * 100 + (components.month ?? 0)
      if let interval = calendar.dateInterval(of: .month, for: rowDate) {
        month = (key, interval.start, interval.end)
      } else {
        month = nil
      }
      buckets[key, default: []].append(row)
    }

    var index = 0
    return buckets.keys.sorted(by: >).map { key in
      let sorted = buckets[key, default: []].sorted { lhs, rhs in
        let lhsDate = date(lhs), rhsDate = date(rhs)
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return id(lhs) > id(rhs)
      }
      let items = sorted.enumerated().map { offset, row in
        defer { index += 1 }
        return makeItem(row, ChatInfoResourcePlacement(
          index: index,
          position: ChatInfoResourceRowPosition(index: offset, count: sorted.count)
        ))
      }
      return ChatInfoResourceSection(
        id: key,
        title: ChatInfoResourceFormat.monthTitle(key: key, sample: date(sorted[0])),
        items: items
      )
    }
  }
}

/// Where an item lands once grouped.
struct ChatInfoResourcePlacement: Equatable {
  /// Position across every section, for pagination and prefetching.
  let index: Int
  /// Position inside its month's card.
  let position: ChatInfoResourceRowPosition
}

/// A row of a list tab, prepared once per page.
struct ChatInfoResourceListItem<Row: Equatable>: Identifiable, Equatable {
  let id: Int64
  let placement: ChatInfoResourcePlacement
  let row: Row
}

/// What a list tab keeps across renders: its sections and pagination.
@MainActor
final class ChatInfoResourceListModel<Row: Equatable, Item> {
  let pager = ChatInfoResourcePager()
  let cache = ChatInfoResourceSectionCache<Row, Item>()

  func itemAppeared<WindowRow>(_ index: Int, window: ChatResourceWindow<WindowRow>) {
    // About a screen of rows before the end.
    pager.itemAppeared(at: index, count: cache.items.count, lookahead: 12, in: window)
  }
}

// MARK: - Pagination

/// Asks a resource window for its next page at most once per loaded row count.
///
/// Cells report their position on appear, which is a compare, not a task; the one
/// `loadMore` call happens when a cell lands within `lookahead` of the end.
@MainActor
final class ChatInfoResourcePager {
  private var requestedCount = -1

  func itemAppeared<Row>(at index: Int, count: Int, lookahead: Int, in window: ChatResourceWindow<Row>) {
    guard index >= count - lookahead else { return }
    requestMore(window)
  }

  /// Not gated on `loadState`: `loadMore` widens the window over cached rows at once,
  /// so history already on the device keeps scrolling while a fetch is slow or failed.
  /// The first page belongs to `loadInitial`.
  func requestMore<Row>(_ window: ChatResourceWindow<Row>) {
    let count = window.rows.count
    guard count > 0, window.hasMore, requestedCount != count else { return }
    requestedCount = count
    Task { await window.loadMore() }
  }

  func retry<Row>(_ window: ChatResourceWindow<Row>) {
    requestedCount = -1
    Task { await window.retry() }
  }
}

// MARK: - Formatting

/// Formatters built once; the tabs used to create a `DateFormatter` per section per body.
@MainActor
enum ChatInfoResourceFormat {
  static let calendar = Calendar.autoupdatingCurrent

  private static func formatter(template: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  private static let month = formatter(template: "MMMM")
  private static let monthYear = formatter(template: "MMMMy")
  private static let dayMonth = formatter(template: "MMMd")
  private static let dayMonthYear = formatter(template: "yMMMd")
  private static let weekday = formatter(template: "EEEE")
  private static let time: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  private static let byteCount: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter
  }()

  private static var monthTitles: [Int: String] = [:]

  /// "November" this year, "November 2025" before.
  static func monthTitle(key: Int, sample: Date) -> String {
    if let title = monthTitles[key] { return title }
    let currentYear = calendar.component(.year, from: Date())
    let title = key / 100 == currentYear ? month.string(from: sample) : monthYear.string(from: sample)
    monthTitles[key] = title
    return title
  }

  /// A row's date: the time today, then "Yesterday", the weekday this week, "Nov 3" this year.
  static func rowDate(_ date: Date) -> String {
    if calendar.isDateInToday(date) { return time.string(from: date) }
    if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
    let now = Date()
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days >= 0, days < 6 {
      return weekday.string(from: date)
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return dayMonth.string(from: date)
    }
    return dayMonthYear.string(from: date)
  }

  static func fileSize(_ bytes: Int) -> String {
    byteCount.string(fromByteCount: Int64(max(bytes, 0)))
  }

  /// "0:42", "12:05", "1:02:09".
  static func duration(_ seconds: Int) -> String {
    let clamped = max(seconds, 0)
    let hours = clamped / 3600
    let minutes = clamped % 3600 / 60
    let rest = clamped % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, rest)
    }
    return String(format: "%d:%02d", minutes, rest)
  }
}

// MARK: - Row chrome

/// Where a row sits in its month's card, which decides its corners and separator.
struct ChatInfoResourceRowPosition: Equatable {
  let isFirst: Bool
  let isLast: Bool

  init(index: Int, count: Int) {
    isFirst = index == 0
    isLast = index == count - 1
  }
}

enum ChatInfoResourceMetrics {
  static let cardInset: CGFloat = 16
  static let cornerRadius: CGFloat = 12
  static let rowHorizontalPadding: CGFloat = 16
  static let rowVerticalPadding: CGFloat = 8
  static let tileSize: CGFloat = 40
  static let tileCornerRadius: CGFloat = 8
  static let tileSpacing: CGFloat = 12
  /// Separators start under the title, as in Settings.
  static var separatorInset: CGFloat { rowHorizontalPadding + tileSize + tileSpacing }
  static var cardBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }
}

/// A month title above a card, styled like the page's other section titles.
struct ChatInfoResourceSectionHeader: View {
  let title: String
  /// Aligns with the text inside a card by default; the edge-to-edge grid passes less.
  var inset: CGFloat = ChatInfoResourceMetrics.cardInset + ChatInfoResourceMetrics.rowHorizontalPadding

  var body: some View {
    Text(title)
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(.uppercase)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, inset)
      .padding(.top, 18)
      .padding(.bottom, 7)
      .accessibilityAddTraits(.isHeader)
  }
}

@available(iOS 17.0, *)
extension View {
  /// Draws one row's slice of an inset grouped card, so a month of thousands of
  /// rows stays lazy instead of living in one card-sized `VStack`.
  func chatInfoResourceRow(_ position: ChatInfoResourceRowPosition) -> some View {
    modifier(ChatInfoResourceRowChrome(position: position))
  }
}

@available(iOS 16.0, *)
private struct ChatInfoResourceRowChrome: ViewModifier {
  let position: ChatInfoResourceRowPosition
  @Environment(\.displayScale) private var displayScale

  private var shape: UnevenRoundedRectangle {
    let radius = ChatInfoResourceMetrics.cornerRadius
    return UnevenRoundedRectangle(
      topLeadingRadius: position.isFirst ? radius : 0,
      bottomLeadingRadius: position.isLast ? radius : 0,
      bottomTrailingRadius: position.isLast ? radius : 0,
      topTrailingRadius: position.isFirst ? radius : 0,
      style: .continuous
    )
  }

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ChatInfoResourceMetrics.cardBackground, in: shape)
      .overlay(alignment: .bottom) {
        if !position.isLast {
          Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, ChatInfoResourceMetrics.separatorInset)
            .accessibilityHidden(true)
        }
      }
      // Keeps a pressed highlight inside the card's rounded ends.
      .clipShape(shape)
      .contentShape(.contextMenuPreview, shape)
      .contentShape(.interaction, Rectangle())
      .padding(.horizontal, ChatInfoResourceMetrics.cardInset)
  }
}

/// Highlights a pressed row the way grouped lists do.
struct ChatInfoResourceRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color(uiColor: .systemFill) : .clear)
  }
}
