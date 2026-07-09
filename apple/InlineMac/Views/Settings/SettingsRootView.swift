import InlineKit
import InlineUI
import SwiftUI

struct SettingsRootView: View {
  @EnvironmentStateObject private var root: RootData
  @State private var selectedCategory: SettingsCategory = .general
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var navigationHistory: [SettingsCategory] = [.general]
  @State private var historyIndex = 0
  @State private var isHistoryNavigation = false

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SettingsSidebarView(selectedCategory: $selectedCategory)
        .frame(minWidth: Metrics.sidebarMinWidth)
        .navigationSplitViewColumnWidth(
          min: Metrics.sidebarMinWidth,
          ideal: Metrics.sidebarIdealWidth,
          max: Metrics.sidebarMaxWidth
        )
        .toolbar(removing: .sidebarToggle)
    } detail: {
      NavigationStack {
        SettingsDetailView(category: selectedCategory)
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
    .onChange(of: selectedCategory) { _, _ in
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
    selectedCategory = navigationHistory[historyIndex]
    DispatchQueue.main.async {
      isHistoryNavigation = false
    }
  }

  private func goForward() {
    guard canGoForward else { return }
    isHistoryNavigation = true
    historyIndex += 1
    selectedCategory = navigationHistory[historyIndex]
    DispatchQueue.main.async {
      isHistoryNavigation = false
    }
  }

  private func recordNavigation() {
    guard !isHistoryNavigation else { return }
    if navigationHistory[historyIndex] == selectedCategory {
      return
    }
    if historyIndex < navigationHistory.count - 1 {
      navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
    }
    navigationHistory.append(selectedCategory)
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
  SettingsRootView()
    .previewsEnvironment(.populated)
}
