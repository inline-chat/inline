import InlineKit
import InlineUI
import SwiftUI

struct SettingsRootView: View {
  @EnvironmentStateObject private var root: RootData
  @State private var selectedCategory: SettingsCategory = .general
  @State private var detailPath: [SettingsDetailRoute] = []
  @State private var navigationHistory: [SettingsNavigationState] = [
    SettingsNavigationState(category: .general, detailPath: []),
  ]
  @State private var historyIndex = 0
  @State private var isHistoryNavigation = false

  init() {
    _root = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
  }

  @Environment(\.auth) var auth

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      SettingsSidebarView(selectedCategory: $selectedCategory)
        .frame(minWidth: Metrics.sidebarMinWidth)
        .navigationSplitViewColumnWidth(
          min: Metrics.sidebarMinWidth,
          ideal: Metrics.sidebarIdealWidth,
          max: Metrics.sidebarMaxWidth
        )
        .toolbar(removing: .sidebarToggle)
    } detail: {
      NavigationStack(path: $detailPath) {
        SettingsDetailView(category: selectedCategory)
      }
    }
    .navigationTitle("Settings")
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          goBack()
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(!canGoBack)

        Button {
          goForward()
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(!canGoForward)
      }
    }
    .onChange(of: selectedCategory) { _, _ in
      if !isHistoryNavigation {
        detailPath = []
      }
      recordNavigation()
    }
    .onChange(of: detailPath) { _, _ in
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
    applyHistory(navigationHistory[historyIndex])
    DispatchQueue.main.async {
      isHistoryNavigation = false
    }
  }

  private func goForward() {
    guard canGoForward else { return }
    isHistoryNavigation = true
    historyIndex += 1
    applyHistory(navigationHistory[historyIndex])
    DispatchQueue.main.async {
      isHistoryNavigation = false
    }
  }

  private func recordNavigation() {
    guard !isHistoryNavigation else { return }
    let snapshot = SettingsNavigationState(category: selectedCategory, detailPath: detailPath)
    if navigationHistory.last == snapshot {
      return
    }
    if historyIndex < navigationHistory.count - 1 {
      navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
    }
    navigationHistory.append(snapshot)
    historyIndex = navigationHistory.count - 1
  }

  private func applyHistory(_ state: SettingsNavigationState) {
    selectedCategory = state.category
    detailPath = state.detailPath
  }
}

private enum Metrics {
  static let sidebarMinWidth: CGFloat = 150
  static let sidebarIdealWidth: CGFloat = 200
  static let sidebarMaxWidth: CGFloat = 250
}

private struct SettingsNavigationState: Equatable {
  let category: SettingsCategory
  let detailPath: [SettingsDetailRoute]
}

enum SettingsDetailRoute: Hashable {
  case screen(String)
}

struct SettingsDetailView: View {
  let category: SettingsCategory

  var body: some View {
    Group {
      switch category {
        case .general:
          GeneralSettingsDetailView()
        #if SPARKLE
        case .updates:
          UpdatesSettingsDetailView()
        #endif
        case .appearance:
          AppearanceSettingsDetailView()
        case .account:
          AccountSettingsDetailView()
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
