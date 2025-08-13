import InlineKit
import InlineUI
import SwiftUI

struct SettingsRootView: View {
  @State private var selectedCategory: SettingsCategory = .general
  @Environment(\.auth) var auth

  var body: some View {
    NavigationSplitView {
      SettingsSidebarView(selectedCategory: $selectedCategory)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
    } detail: {
      SettingsDetailView(category: selectedCategory)
    }
    .navigationTitle("Settings")
    .navigationSplitViewStyle(.balanced)
  }
}

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

    categories.append(contentsOf: [.general])

    return categories
  }
}

struct SettingsCategoryRow: View {
  let category: SettingsCategory

  var body: some View {
    Label {
      Text(category.title)
        .foregroundStyle(.primary)
    } icon: {
      Image(systemName: category.iconName)
    }
  }
}

struct SettingsDetailView: View {
  let category: SettingsCategory

  var body: some View {
    Group {
      switch category {
        case .general:
          GeneralSettingsDetailView()
        case .appearance:
          AppearanceSettingsDetailView()
        case .account:
          AccountSettingsDetailView()
      }
    }
    .navigationTitle(category.title)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

#Preview {
  SettingsRootView()
    .previewsEnvironment(.populated)
}
