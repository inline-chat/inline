import Foundation
import InlineKit
import InlineUI
import SwiftUI

struct SettingsSidebarView: View {
  @Binding var selectedCategory: SettingsCategory
  @Environment(\.auth) var auth

  var body: some View {
    List(selection: $selectedCategory) {
      ForEach(availableCategories) { category in
        SettingsCategoryRow(category: category)
          .tag(category)
      }
      SettingsSidebarFooterView()
    }
    .listStyle(.sidebar)
    .scrollEdgeEffectStyleSoftIfAvailable()
    .navigationTitle("Settings")
  }

  private
  var availableCategories: [SettingsCategory] {
    var categories: [SettingsCategory] = []

    if auth.isLoggedIn {
      categories.append(.account)
    }

    // more items
    categories.append(.general)
#if SPARKLE
    categories.append(.updates)
#endif
    categories.append(contentsOf: [.appearance, .notifications, .experimental])

    if auth.isLoggedIn {
      categories.append(.bots)
    }
    categories.append(.debug)

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

struct SettingsCategoryRow: View {
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

struct AccountSettingsRow: View {
  @EnvironmentObject private var root: RootData

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      UserAvatar(userInfo: root.currentUserInfo ?? .deleted, size: 36)

      VStack(alignment: .leading, spacing: 0) {
        Text(root.currentUser?.fullName ?? "User not loaded")
          .font(.body)
          .fontWeight(.medium)
        
        if let username = root.currentUser?.username {
          Text("@\(username)")
            .font(.caption)
        }
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
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .fontDesign(.monospaced)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
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
