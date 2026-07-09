import Foundation
import InlineKit
import InlineUI
import SwiftUI

struct SettingsSidebarView: View {
  @Binding var selectedCategory: SettingsCategory
  @Environment(\.auth) private var auth

  var body: some View {
    List(selection: $selectedCategory) {
      ForEach(availableCategories) { category in
        SettingsCategoryRow(category: category)
          .tag(category)
      }
    }
    .listStyle(.sidebar)
    .scrollEdgeEffectStyleSoftIfAvailable()
    .navigationTitle("Settings")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SettingsSidebarFooterView()
    }
  }

  private var availableCategories: [SettingsCategory] {
    var categories: [SettingsCategory] = []

    if auth.isLoggedIn {
      categories.append(.account)
    }

    categories.append(contentsOf: [.general, .appearance, .notifications, .dataStorage])
#if SPARKLE
    categories.append(.updates)
#endif
    categories.append(.hotkeys)

    if auth.isLoggedIn {
      categories.append(.bots)
      categories.append(.activeSessions)
    }

    categories.append(contentsOf: [.experimental, .debug])
    return categories
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
        Image(systemName: category.iconName)
      }
      .foregroundStyle(.primary)
    }
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
