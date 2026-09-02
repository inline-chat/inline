import AppIntents
import InlineAppIntents
import InlineKit
import Auth
import UIKit

/// The app only registers the module and its entry phrases. All execution stays in InlineAppIntents.
struct InlineIOSIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [InlineAppIntentsPackage.self] }
}

struct InlineShortcuts: AppShortcutsProvider {
  @MainActor
  static func registerNavigation(routerRegistry: IOSSceneRouterRegistry) {
    let navigation = InlineIntentNavigation { peer, accountID in
      routerRegistry.navigate(.chat(peer: peer), accountUserID: accountID)
    }
    AppDependencyManager.shared.add(dependency: navigation)
    AppDependencyManager.shared.add(dependency: InlineIntentDraftNavigation { peer, account, text in
      try Auth.shared.handle.validateAccountMutation(account)
      guard routerRegistry.navigate(.chat(peer: peer), accountUserID: account.userID) else { throw InlineIntentError.accountChanged }
      for _ in 0 ..< 40 {
        try Task.checkCancellation()
        try Auth.shared.handle.validateAccountMutation(account)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        for window in windows where !window.isHidden {
          if let composer = findComposer(in: window, peer: peer) {
            guard composer.acceptExternalDraft(text, for: peer) else { throw InlineIntentError.draftInProgress }
            return
          }
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw InlineIntentError.unavailable
    })
  }

  @MainActor
  private static func findComposer(in view: UIView, peer: InlineKit.Peer) -> ComposeView? {
    guard !view.isHidden else { return nil }
    if let composer = view as? ComposeView, composer.peerId == peer { return composer }
    for child in view.subviews {
      if let composer = findComposer(in: child, peer: peer) { return composer }
    }
    return nil
  }

  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: FindUnreadInlineChatsIntent(),
      phrases: ["Check my unread chats in \(.applicationName)"],
      shortTitle: "Unread Chats",
      systemImageName: "bubble.left.badge.exclamationmark"
    )
    AppShortcut(
      intent: ReadInlineMessagesIntent(),
      phrases: ["Get my unread messages in \(.applicationName)"],
      shortTitle: "Get Messages",
      systemImageName: "text.bubble"
    )
    AppShortcut(
      intent: OpenInlineChatIntent(),
      phrases: ["Open a chat in \(.applicationName)"],
      shortTitle: "Open Chat",
      systemImageName: "bubble.left.and.bubble.right"
    )
    AppShortcut(
      intent: SendInlineMessageIntent(),
      phrases: ["Send a message in \(.applicationName)"],
      shortTitle: "Send Message",
      systemImageName: "paperplane"
    )
    AppShortcut(
      intent: SaveInlineNoteIntent(),
      phrases: ["Save a note in \(.applicationName)"],
      shortTitle: "Save a Note",
      systemImageName: "bookmark"
    )
  }
}
