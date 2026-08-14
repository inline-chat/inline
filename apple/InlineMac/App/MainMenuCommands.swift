import AppKit
import InlineKit
import Translation

/// Semantic commands exposed by the macOS main menu and other app surfaces.
/// Keep these independent from `NSMenuItem` so App Intents can reuse them later.
enum ChatMenuCommand: Int {
  case showInfo
  case copyLink
  case openNewTab
  case openNewWindow
  case rename
  case toggleRead
  case toggleFollow
  case openInSidebar
  case togglePin
  case toggleArchive

  var identifier: NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier("chat.\(String(describing: self))")
  }
}

struct ChatMenuContext {
  let peer: Peer
  let isUnread: Bool
  let isFollowing: Bool
  let isOpenInSidebar: Bool
  let isPinned: Bool
  let isArchived: Bool
  let canRename: Bool
  let perform: @MainActor (ChatMenuCommand) -> Void

  static func placeholderTitle(for command: ChatMenuCommand) -> String {
    switch command {
    case .showInfo: "Show Chat Info"
    case .copyLink: "Copy Link"
    case .openNewTab: "Open Chat in New Tab"
    case .openNewWindow: "Open Chat in New Window"
    case .rename: "Rename Thread…"
    case .toggleRead: "Mark as Unread"
    case .toggleFollow: "Follow"
    case .openInSidebar: "Open in Sidebar"
    case .togglePin: "Pin"
    case .toggleArchive: "Archive"
    }
  }

  func title(for command: ChatMenuCommand) -> String {
    switch command {
    case .showInfo: "Show Chat Info"
    case .copyLink: "Copy Link"
    case .openNewTab: "Open Chat in New Tab"
    case .openNewWindow: "Open Chat in New Window"
    case .rename: "Rename Thread…"
    case .toggleRead: isUnread ? "Mark as Read" : "Mark as Unread"
    case .toggleFollow: isFollowing ? "Unfollow" : "Follow"
    case .openInSidebar: "Open in Sidebar"
    case .togglePin: isPinned ? "Unpin" : "Pin"
    case .toggleArchive: isArchived ? "Unarchive" : "Archive"
    }
  }

  func isEnabled(_ command: ChatMenuCommand) -> Bool {
    switch command {
    case .rename:
      canRename
    case .toggleFollow:
      peer.isThread
    case .openInSidebar:
      !isOpenInSidebar
    default:
      true
    }
  }
}

struct SpaceMenuContext {
  struct Item: Equatable {
    let id: Int64
    let name: String
  }

  let selectedSpaceID: Int64?
  let spaces: [Item]
  let selectHome: @MainActor () -> Void
  let selectSpace: @MainActor (Int64) -> Void
  let createSpace: @MainActor () -> Void
  let showSettings: @MainActor (Int64) -> Void
  let showMembers: @MainActor (Int64) -> Void
  let showIntegrations: @MainActor (Int64) -> Void
  let showGrid: @MainActor (Int64) -> Void
  let invitePeople: @MainActor (Int64?) -> Void
}

@MainActor
enum ChatMenuActions {
  static func copyLink(for peer: Peer) {
    let url: URL? = switch peer {
    case let .user(id): InlineDeepLink.user(id: id).url
    case let .thread(id): InlineDeepLink.chat(id: id).url
    }

    guard let url else {
      ToastCenter.shared.showError("Failed to copy link")
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(url.absoluteString, forType: .string) else {
      ToastCenter.shared.showError("Failed to copy link")
      return
    }
    ToastCenter.shared.showSuccess("Copied link")
  }

  static func openInSidebar(peer: Peer, isHidden: Bool, dependencies: AppDependencies) {
    Task(priority: .userInitiated) {
      do {
        if peer.isThread, isHidden {
          _ = try await dependencies.realtimeV2.send(.showInChatList(peerId: peer))
        }
        _ = try await dependencies.realtimeV2.send(.updateDialogOpen(peerId: peer, open: true))
        await MainActor.run { ToastCenter.shared.showSuccess("Kept in sidebar") }
      } catch {
        await MainActor.run { ToastCenter.shared.showError("Failed to open chat in sidebar") }
      }
    }
  }

  static func togglePin(peer: Peer, isPinned: Bool, spaceID: Int64?) {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(
          peerId: peer,
          pinned: !isPinned,
          spaceId: spaceID
        )
      } catch {
        await MainActor.run { ToastCenter.shared.showError("Failed to update pin") }
      }
    }
  }

  static func toggleArchive(peer: Peer, isArchived: Bool, spaceID: Int64?) {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(
          peerId: peer,
          archived: !isArchived,
          spaceId: spaceID
        )
      } catch {
        await MainActor.run { ToastCenter.shared.showError("Failed to update archive") }
      }
    }
  }
}

@MainActor
enum AppRecoveryActions {
  static func clearCache(confirming: Bool) {
    if confirming {
      let alert = NSAlert()
      alert.messageText = "Clear Cache"
      alert.informativeText = "This clears local cached app data and sync state. Inline will reload your account from the server."
      alert.addButton(withTitle: "Cancel")
      alert.alertStyle = .warning
      let clearButton = alert.addButton(withTitle: "Clear Cache")
      clearButton.hasDestructiveAction = true
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }

    Task { @MainActor in
      guard let appDelegate = NSApp.delegate as? AppDelegate else {
        ToastCenter.shared.showError("Failed to clear cache")
        return
      }
      do {
        try await appDelegate.clearCacheAndResetApp()
        ToastCenter.shared.showSuccess("Cache cleared")
      } catch {
        ToastCenter.shared.showError("Failed to clear cache")
      }
    }
  }

  static func clearMediaCache() {
    Task {
      do {
        try await FileCache.shared.clearCache()
        await MainActor.run { ToastCenter.shared.showSuccess("Media cache cleared") }
      } catch {
        await MainActor.run { ToastCenter.shared.showError("Failed to clear media cache") }
      }
    }
  }

  static func resetDismissedPopovers() {
    TranslationAlertDismiss.shared.resetAllDismissStates()
    ToastCenter.shared.showSuccess("Dismissed popovers reset")
  }
}
