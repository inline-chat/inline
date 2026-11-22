import Foundation
import SwiftUI

/// A searchable list of every time zone, by city, region and GMT offset.
public struct TimeZonePickerList: View {
  private let selection: TimeZone?
  private let onSelect: (TimeZone) -> Void
  @State private var query = ""

  public init(selection: TimeZone?, onSelect: @escaping (TimeZone) -> Void) {
    self.selection = selection
    self.onSelect = onSelect
  }

  public var body: some View {
    List {
      ForEach(filtered) { entry in
        Button {
          onSelect(entry.timeZone)
        } label: {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.city)
                .foregroundStyle(.primary)
              Text(entry.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(TimeZoneEntry.offset(entry.timeZone))
              .font(.callout)
              .monospacedDigit()
              .foregroundStyle(.secondary)
            Image(systemName: "checkmark")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.tint)
              .opacity(entry.id == selection?.identifier ? 1 : 0)
              .accessibilityHidden(entry.id != selection?.identifier)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(entry.id == selection?.identifier ? .isSelected : [])
      }
      if filtered.isEmpty {
        Text("No time zones found")
          .foregroundStyle(.secondary)
      }
    }
    .searchable(text: $query, prompt: "Search cities or time zones")
  }

  private var filtered: [TimeZoneEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return TimeZoneEntry.all }
    return TimeZoneEntry.all.filter { $0.searchText.localizedStandardContains(trimmed) }
  }
}

public extension TimeZone {
  /// "Tokyo (GMT+9)", for a settings row that shows a picked time zone.
  var pickerTitle: String {
    "\(TimeZoneEntry.city(identifier)) (\(TimeZoneEntry.offset(self)))"
  }
}

struct TimeZoneEntry: Identifiable {
  let timeZone: TimeZone
  let city: String
  let detail: String
  let searchText: String

  var id: String { timeZone.identifier }

  /// Names are built once; offsets are read per row so they follow daylight saving.
  static let all: [TimeZoneEntry] = TimeZone.knownTimeZoneIdentifiers.compactMap { identifier in
    // Skip aliases like "GMT" and "UTC" without a region; keep real places.
    guard identifier.contains("/"), let timeZone = TimeZone(identifier: identifier) else { return nil }
    let city = Self.city(identifier)
    let region = identifier.split(separator: "/").first.map(String.init) ?? ""
    let name = timeZone.localizedName(for: .generic, locale: .current) ?? ""
    let detail = name.isEmpty ? region : "\(name) · \(region)"
    return TimeZoneEntry(
      timeZone: timeZone,
      city: city,
      detail: detail,
      searchText: "\(city) \(identifier) \(name)"
    )
  }
  .sorted { $0.city.localizedStandardCompare($1.city) == .orderedAscending }

  static func city(_ identifier: String) -> String {
    (identifier.split(separator: "/").last.map(String.init) ?? identifier)
      .replacingOccurrences(of: "_", with: " ")
  }

  static func offset(_ timeZone: TimeZone, at date: Date = Date()) -> String {
    let seconds = timeZone.secondsFromGMT(for: date)
    guard seconds != 0 else { return "GMT" }
    let sign = seconds > 0 ? "+" : "-"
    let hours = abs(seconds) / 3_600
    let minutes = (abs(seconds) % 3_600) / 60
    return minutes == 0 ? "GMT\(sign)\(hours)" : String(format: "GMT\(sign)%d:%02d", hours, minutes)
  }
}
