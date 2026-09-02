import SwiftUI

/// Uses the existing scene presentation owner, including chat-owned UIKit sheets.
@MainActor
struct IPadSceneCommandGate {
  let registry: IOSSceneRouterRegistry
  let sceneID: UUID

  func canPerform() -> Bool {
    registry.canPerformNavigation(in: sceneID)
  }
}

extension FocusedValues {
  @Entry var iPadSceneCommandGate: IPadSceneCommandGate?
}

/// Resolved by the active authenticated scene; no global router or closure capture.
@available(iOS 26.0, *)
struct IPadNavigationContext {
  let router: Router
}

/// Plain request state is available to the shared root; command UI stays iPadOS 26+.
enum IPadCommandRequest: Hashable {
  case newThread
  case openArchive
}

@available(iOS 26.0, *)
extension FocusedValues {
  @Entry var iPadNavigationContext: IPadNavigationContext?
  @Entry var iPadSidebarScope: Binding<IPadSidebarScope>?
  @Entry var iPadCommandRequest: Binding<IPadCommandRequest?>?
}

@MainActor
@available(iOS 26.0, *)
struct IPadCommands: Commands {
  @FocusedValue(\.iPadNavigationContext) private var context
  @FocusedBinding(\.iPadSidebarScope) private var sidebarScope
  @FocusedValue(\.iPadCommandRequest) private var commandRequest
  @FocusedValue(\.iPadSceneCommandGate) private var sceneGate

  var body: some Commands {
    SidebarCommands()
    CommandGroup(after: .sidebar) {
      Picker("Chat List", selection: $sidebarScope) {
        Text("All Chats").tag(IPadSidebarScope.allChats as IPadSidebarScope?)
        Text("Open").tag(IPadSidebarScope.open as IPadSidebarScope?)
      }
      .disabled(sidebarScope == nil || !canPerform)

      Divider()

      Button("Back", systemImage: "chevron.backward") { perform { $0.goBack() } }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(context?.router.canGoBack != true || !canPerform)
      Button("Forward", systemImage: "chevron.forward") { perform { $0.goForward() } }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(context?.router.canGoForward != true || !canPerform)
    }
    CommandGroup(after: .newItem) {
      Button("New Thread", systemImage: "square.and.pencil") { request(.newThread) }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(commandRequest == nil || !canPerform)
    }
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { perform { $0.presentSheet(.settings) } }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(context == nil || !canPerform)
    }
    CommandMenu("Chat") {
      Button("Archived Chats", systemImage: "archivebox") { request(.openArchive) }
        .disabled(commandRequest == nil || !canPerform)
    }
  }

  private var canPerform: Bool {
    context != nil && context?.router.presentedSheet == nil && sceneGate?.canPerform() == true
  }

  private func perform(_ action: (Router) -> Void) {
    // Recheck at invocation: a sheet can appear after menu validation.
    guard canPerform, let router = context?.router else { return }
    action(router)
  }

  private func request(_ request: IPadCommandRequest) {
    guard canPerform, let commandRequest else { return }
    commandRequest.wrappedValue = request
  }
}
