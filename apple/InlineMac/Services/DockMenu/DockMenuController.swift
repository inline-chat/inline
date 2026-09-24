import AppKit
import Auth
import GRDB
import InlineKit
import Logger

/// Owns Dock-only data and actions. AppDelegate only forwards the system menu request.
@MainActor
final class DockMenuController {
  private let database: AppDatabase
  private let presentation = DockMenu()
  private let log = Log.scoped("DockMenu")

  init(database: AppDatabase) {
    self.database = database
  }

  func makeMenu() -> NSMenu? {
    guard let owner = try? Auth.shared.handle.beginAccountMutation() else { return nil }

    do {
      let snapshot = try database.reader.read { db in
        try Auth.shared.handle.validateAccountMutation(owner)
        return try DockMenuSnapshot.fetch(db)
      }
      try Auth.shared.handle.validateAccountMutation(owner)

      let chats = snapshot.chats.prefix(DockMenu.chatLimit).map { chat in
        DockMenu.Chat(title: chat.title) {
          MainWindowOpenCoordinator.shared.openWindow(.chat(peer: chat.peer), expectedAccount: owner)
        }
      }
      return presentation.makeMenu(chats: chats, totalCount: snapshot.chats.count) { [weak self] in
        self?.markAllRead(snapshot, owner: owner)
      }
    } catch {
      guard (try? Auth.shared.handle.validateAccountMutation(owner)) != nil else { return nil }
      log.error("Failed to load Dock unread chats", error: error)
      return presentation.unavailableMenu()
    }
  }

  private func markAllRead(_ snapshot: DockMenuSnapshot, owner: AuthAccountMutationToken) {
    var hasUnavailableChat = false
    for chat in snapshot.chats {
      guard (try? Auth.shared.handle.validateAccountMutation(owner)) != nil else { return }
      guard let chatID = chat.chatID else {
        hasUnavailableChat = true
        continue
      }
      UnreadManager.shared.readAll(chat.peer, chatId: chatID)
    }
    if hasUnavailableChat {
      ToastCenter.shared.showError("Some chats are still loading. Open Inline and try again.")
    }
  }
}
