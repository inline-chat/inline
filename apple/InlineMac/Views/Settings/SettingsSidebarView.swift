import Foundation
import InlineKit
import InlineUI
import SwiftUI

struct SettingsSidebarView: View {
  @Bindable var navigation: SettingsNavigationModel
  @Environment(\.auth) private var auth
  @ObservedObject private var settings = AppSettings.shared
  @FocusState private var focus: SettingsSidebarFocus?
  @State private var selectedSearchItem: SettingsSearchItem?

  var body: some View {
    sidebarList
      .focused($focus, equals: .list)
      .listStyle(.sidebar)
      .background(sidebarTint)
      .animation(.easeInOut(duration: 0.18), value: settings.sidebarGlassAndTintEnabled)
      .scrollEdgeEffectStyleSoftIfAvailable()
      .navigationTitle("Settings")
      .searchable(text: $navigation.searchQuery, placement: .sidebar, prompt: "Search")
      .searchFocused($focus, equals: .search)
      // Keep the list focused on open so the search field doesn't steal focus and restyle the selected row.
      .defaultFocus($focus, .list)
      .onChange(of: navigation.searchFocusRequest) { _, _ in
        focus = .search
      }
      .onChange(of: navigation.searchQuery) { _, _ in
        selectedSearchItem = nil
      }
      .onChange(of: selectedSearchItem) { _, item in
        if let item {
          navigation.reveal(item)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SettingsSidebarFooterView()
      }
  }

  @ViewBuilder
  private var sidebarList: some View {
    if isSearching {
      let groups = searchResultGroups
      List(selection: $selectedSearchItem) {
        ForEach(groups) { group in
          Section {
            ForEach(group.items) { item in
              SettingsSearchResultRow(item: item)
                .tag(item)
                // Selection doesn't change when re-clicking the selected result; reveal it again anyway.
                .simultaneousGesture(TapGesture().onEnded { navigation.reveal(item) })
            }
          } header: {
            HStack(spacing: 4) {
              SettingsCategoryIcon(category: group.category, size: 14)
              Text(group.category.title)
            }
          }
        }
      }
      .overlay {
        if groups.isEmpty {
          ContentUnavailableView.search(text: trimmedQuery)
        }
      }
    } else {
      List(selection: $navigation.selectedCategory) {
        ForEach(categoryGroups, id: \.self) { group in
          Section {
            ForEach(group) { category in
              SettingsCategoryRow(category: category)
                .tag(category)
            }
          }
        }
      }
    }
  }

  private var sidebarTint: Color {
    _ = settings.themeRevision
    return Color(nsColor: Theme.sidebarOverlayColor)
  }

  private var categoryGroups: [[SettingsCategory]] {
    SettingsCategory.sidebarGroups(isLoggedIn: auth.isLoggedIn)
  }

  private var availableCategories: [SettingsCategory] {
    SettingsCategory.available(isLoggedIn: auth.isLoggedIn)
  }

  private var trimmedQuery: String {
    navigation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool {
    !trimmedQuery.isEmpty
  }

  /// Results grouped by category, with groups ordered by their best-ranked result.
  private var searchResultGroups: [SettingsSearchResultGroup] {
    let entries = SettingsSearchItem.searchEntries(for: availableCategories)
    var groups: [SettingsSearchResultGroup] = []
    for item in SettingsSearch.results(for: trimmedQuery, in: entries) {
      if let index = groups.firstIndex(where: { $0.category == item.category }) {
        groups[index].items.append(item)
      } else {
        groups.append(SettingsSearchResultGroup(category: item.category, items: [item]))
      }
    }
    return groups
  }
}

private enum SettingsSidebarFocus: Hashable {
  case list
  case search
}

private struct SettingsSearchResultGroup: Identifiable {
  let category: SettingsCategory
  var items: [SettingsSearchItem]

  var id: SettingsCategory { category }
}

private struct SettingsSearchResultRow: View {
  let item: SettingsSearchItem

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(item.title)
        .lineLimit(1)

      Text(item.section)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.vertical, 2)
  }
}

private extension View {
  @ViewBuilder
  func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
    if #available(macOS 26.0, *) {
      scrollEdgeEffectStyle(.soft, for: .all)
    } else {
      self
    }
  }
}

private struct SettingsCategoryRow: View {
  let category: SettingsCategory

  var body: some View {
    if category == .account {
      AccountSettingsRow()
    } else {
      Label {
        Text(category.title)
      } icon: {
        SettingsCategoryIcon(category: category, size: 22)
      }
      .foregroundStyle(.primary)
      .padding(.vertical, 2)
    }
  }
}

/// Flat colored tile with the category's glyph image centered on it.
private struct SettingsCategoryIcon: View {
  let category: SettingsCategory
  let size: CGFloat

  var body: some View {
    let tile = RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
    ZStack {
      tile.fill(category.iconTileColor)
      tile.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
      Image(category.iconImageName)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: size * 0.7, height: size * 0.7)
        .shadow(color: .black.opacity(0.14), radius: size * 0.025, y: size * 0.015)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private extension SettingsCategory {
  var iconTileColor: Color {
    let hex: UInt32 = switch self {
    case .general: 0xA2A2A6
    case .appearance: 0x7A79EA
    case .notifications: 0xFF665D
    case .audioAndVideo: 0xFF6EB3
    case .privacy: 0x369AFF
    case .dataStorage: 0x51D1C1
    case .activeSessions: 0xA2A2A6
    case .connectors: 0xFFB036
    case .bots: 0x867FFF
    case .hotkeys: 0xEDEDF0
#if SPARKLE
    case .updates: 0x55D976
#endif
    case .experimental: 0xFFC42D
    case .debug: 0xA2A2A6
    case .account: 0xAD79F7
    }
    return Color(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

private struct AccountSettingsRow: View {
  @EnvironmentObject private var root: RootData

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      UserAvatar(userInfo: root.currentUserInfo ?? .deleted, size: 36)

      VStack(alignment: .leading, spacing: 0) {
        Text(root.currentUser?.fullName ?? "User not loaded")
          .font(.body)
          .fontWeight(.medium)

        Text("Your Account")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 4)
  }
}

private struct SettingsSidebarFooterView: View {
  private let footerText = SettingsSidebarFooterView.buildFooterText()

  var body: some View {
    if let footerText {
      Text(footerText)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
  }

  private static func buildFooterText() -> String? {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let commit = commitString()
    var base: String?
    if let version {
      base = "v\(version)"
    } else if let buildNumber {
      base = buildNumber
    }

    if let buildNumber, version != nil {
      base = "\(base ?? "") (\(buildNumber))"
    }

    if let commit {
      let shortCommit = shortCommitString(commit)
      if let base, !base.isEmpty {
        return "\(base) • \(shortCommit)"
      }
      return shortCommit
    }

    return base
  }

  private static func shortCommitString(_ value: String) -> String {
    if value.count > 8 {
      return String(value.prefix(8))
    }
    return value
  }

  private static func commitString() -> String? {
    let keys = ["GitCommit", "GIT_COMMIT", "Commit", "CommitHash"]
    for key in keys {
      if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
         !value.isEmpty {
        return value
      }
    }
    return nil
  }
}
