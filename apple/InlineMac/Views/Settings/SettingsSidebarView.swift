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
    }
    .listStyle(.sidebar)
    .navigationTitle("Settings")
  }

  private
  var availableCategories: [SettingsCategory] {
    var categories: [SettingsCategory] = []

    if auth.isLoggedIn {
      categories.append(.account)
    }

    // more items
    categories.append(contentsOf: [.general, .notifications, .experimental, .debug])

    return categories
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
