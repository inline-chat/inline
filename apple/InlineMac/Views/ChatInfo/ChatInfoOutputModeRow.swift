import InlineKit
import SwiftUI

/// How the bot replies in this direct chat, with its default as a submenu.
/// Shown for bots that report a runtime or declare the Output setting; the
/// same choice as the Agent Settings toolbar menu.
struct ChatInfoOutputModeRow: View {
  let botUserID: Int64
  @ObservedObject private var store = AgentWorkStateStore.shared

  var body: some View {
    Group {
      if store.offersOutputMode(botUserID: botUserID) {
        Divider()

        ChatInfoRow("Output") {
          AgentOutputModeSettingsRow(peer: .user(id: botUserID), botUserID: botUserID, style: .chatInfo)
        }
      }
    }
    .task(id: botUserID) {
      AgentGrantStore.shared.ensureLoaded(botUserID: botUserID)
      await store.loadDirectChatOutputModes(botUserID: botUserID)
    }
  }
}
