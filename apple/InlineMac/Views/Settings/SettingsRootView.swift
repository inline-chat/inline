import InlineKit
import InlineUI
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsNavigationModel {
  var selectedCategory: SettingsCategory

  init(selectedCategory: SettingsCategory = .general) {
    self.selectedCategory = selectedCategory
  }
}

struct SettingsRootView: View {
  @EnvironmentStateObject private var root: RootData
  @Bindable private var navigation: SettingsNavigationModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var navigationHistory: [SettingsCategory]
  @State private var historyIndex = 0
  @State private var isHistoryNavigation = false

  init(navigation: SettingsNavigationModel) {
    self.navigation = navigation
    _navigationHistory = State(initialValue: [navigation.selectedCategory])
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SettingsSidebarView(selectedCategory: $navigation.selectedCategory)
        .frame(minWidth: Metrics.sidebarMinWidth)
        .navigationSplitViewColumnWidth(
          min: Metrics.sidebarMinWidth,
          ideal: Metrics.sidebarIdealWidth,
          max: Metrics.sidebarMaxWidth
        )
        .toolbar(removing: .sidebarToggle)
    } detail: {
      NavigationStack {
        SettingsDetailView(category: navigation.selectedCategory)
      }
    }
    .navigationTitle("Settings")
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        ControlGroup {
          Button {
            goBack()
          } label: {
            Label("Go Back", systemImage: "chevron.left")
              .labelStyle(.iconOnly)
          }
          .disabled(!canGoBack)

          Button {
            goForward()
          } label: {
            Label("Go Forward", systemImage: "chevron.right")
              .labelStyle(.iconOnly)
          }
          .disabled(!canGoForward)
        }
        .controlGroupStyle(.navigation)
      }
    }
    .onChange(of: navigation.selectedCategory) { _, _ in
      recordNavigation()
    }
    .environmentObject(root)
  }

  private var canGoBack: Bool {
    historyIndex > 0
  }

  private var canGoForward: Bool {
    historyIndex < navigationHistory.count - 1
  }

  private func goBack() {
    guard canGoBack else { return }
    isHistoryNavigation = true
    historyIndex -= 1
    navigation.selectedCategory = navigationHistory[historyIndex]
    DispatchQueue.main.async {
      isHistoryNavigation = false
    }
  }

  private func goForward() {
    guard canGoForward else { return }
    isHistoryNavigation = true
    historyIndex += 1
    navigation.selectedCategory = navigationHistory[historyIndex]
    DispatchQueue.main.async {
      isHistoryNavigation = false
    }
  }

  private func recordNavigation() {
    guard !isHistoryNavigation else { return }
    if navigationHistory[historyIndex] == navigation.selectedCategory {
      return
    }
    if historyIndex < navigationHistory.count - 1 {
      navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
    }
    navigationHistory.append(navigation.selectedCategory)
    historyIndex = navigationHistory.count - 1
  }
}

private enum Metrics {
  static let sidebarMinWidth: CGFloat = 200
  static let sidebarIdealWidth: CGFloat = 200
  static let sidebarMaxWidth: CGFloat = 320
  static let windowMinWidth: CGFloat = 780
  static let windowMinHeight: CGFloat = 520
}

private struct SettingsDetailView: View {
  let category: SettingsCategory

  var body: some View {
    Group {
      switch category {
      case .general:
        GeneralSettingsDetailView()
      case .dataStorage:
        DataStorageSettingsDetailView()
      case .hotkeys:
        HotkeysSettingsDetailView()
        #if SPARKLE
      case .updates:
        UpdatesSettingsDetailView()
        #endif
      case .appearance:
        AppearanceSettingsDetailView()
      case .account:
        AccountSettingsDetailView()
      case .activeSessions:
        AccountSessionsSettingsDetailView()
      case .bots:
        BotsSettingsDetailView()
      case .notifications:
        NotificationsSettingsDetailView()
      case .experimental:
        ExperimentalSettingsDetailView()
      case .debug:
        DebugSettingsDetailView()
      }
    }
    .navigationTitle(category.title)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

#Preview {
  SettingsRootView(navigation: SettingsNavigationModel())
    .previewsEnvironment(.populated)
}
