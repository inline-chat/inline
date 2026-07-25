import InlineIntents
import InlineKit
import Logger

enum IntentDonationCoordinator {
  static func donateOutgoing(peerId: Peer, chatId: Int64) {
    Task(priority: .utility) {
      guard let request = await AppDataUpdater.shared.outgoingIntentRequest(
        peerId: peerId,
        chatId: chatId
      ) else {
        Log.shared.debug("Skipped send-message intent donation: conversation metadata unavailable")
        return
      }

      do {
        try await InlineMessageIntentDonation.donate(request)
      } catch {
        Log.shared.warning("Failed to donate send-message intent: \(error.localizedDescription)")
      }
    }
  }

  static func deleteAll() async {
    do {
      try await InlineMessageIntentDonation.deleteAll()
    } catch {
      Log.shared.warning("Failed to clear donated message intents: \(error.localizedDescription)")
    }
  }
}
