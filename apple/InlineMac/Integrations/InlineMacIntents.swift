import AppIntents
import AppKit
import Auth
import InlineAppIntents
import InlineKit

struct InlineMacIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [InlineAppIntentsPackage.self] }
}

/// macOS registers the same first-class shortcuts as iOS; action execution stays in the shared package.
struct InlineMacShortcuts: AppShortcutsProvider {
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

@MainActor
enum InlineMacIntents {
  static func register(isAccountReady: @escaping @MainActor @Sendable () -> Bool) {
    AppDependencyManager.shared.add(dependency: InlineIntentNavigation { peer, accountID in
      guard isAccountReady() else { return false }
      return open(peer, accountID: accountID)
    })
    AppDependencyManager.shared.add(dependency: InlineIntentDraftNavigation { peer, account, text in
      guard isAccountReady() else { throw InlineIntentError.unavailable }
      try Auth.shared.handle.validateAccountMutation(account)
      guard open(peer, accountID: account.userID) else { throw InlineIntentError.accountChanged }
      for _ in 0 ..< 40 {
        try Task.checkCancellation()
        guard isAccountReady() else { throw InlineIntentError.unavailable }
        try Auth.shared.handle.validateAccountMutation(account)
        let windows = NSApp.windows.sorted { $0.isKeyWindow && !$1.isKeyWindow }
        for window in windows where window.isVisible {
          if let root = window.contentView, let accept = findComposer(in: root, peer: peer) {
            guard isAccountReady() else { throw InlineIntentError.unavailable }
            try Auth.shared.handle.validateAccountMutation(account)
            guard accept(text) else { throw InlineIntentError.draftInProgress }
            return
          }
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw InlineIntentError.unavailable
    })
  }

  private static func open(_ peer: Peer, accountID: Int64) -> Bool {
    let auth = Auth.shared.handle
    guard auth.isLoggedIn(), !auth.hasPendingAccountTransition(), auth.snapshot().currentUserId == accountID,
          let account = try? auth.beginAccountMutation() else { return false }
    MainWindowOpenCoordinator.shared.openWindow(.chat(peer: peer), expectedAccount: account)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }

  private static func findComposer(in view: NSView, peer: Peer) -> ((String) -> Bool)? {
    guard !view.isHidden else { return nil }
    if let composer = view as? GlassComposeAppKit, composer.isComposer(for: peer) {
      return { composer.acceptExternalDraft($0, for: peer) }
    }
    if let composer = view as? LegacyComposeAppKit, composer.isComposer(for: peer) {
      return { composer.acceptExternalDraft($0, for: peer) }
    }
    for child in view.subviews {
      if let composer = findComposer(in: child, peer: peer) { return composer }
    }
    return nil
  }
}
