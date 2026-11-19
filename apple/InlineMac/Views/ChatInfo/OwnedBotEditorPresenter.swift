import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import SwiftUI

/// Loads a bot the viewer manages and shows its profile editor or settings.
/// The editors take the server's bot record, which only owners and admins get.
@MainActor
@Observable
final class OwnedBotEditorPresenter {
  enum Kind { case profile, settings }

  struct Presented: Identifiable {
    let kind: Kind
    let bot: InlineProtocol.User
    var id: String { "\(kind)-\(bot.id)" }
  }

  var presented: Presented?
  private(set) var opening: Kind?

  @ObservationIgnored private let log = Log.scoped("OwnedBotEditor")

  func open(_ kind: Kind, botUserID: Int64, realtimeV2: RealtimeV2) {
    guard opening == nil else { return }
    opening = kind
    Task { @MainActor in
      defer { opening = nil }
      do {
        let result = try await realtimeV2.send(.listBots(includeManaged: true))
        guard case let .listBots(response) = result else { throw TransactionExecutionError.invalid }
        guard let bot = response.bots.first(where: { $0.id == botUserID }) else {
          ToastCenter.shared.showError("Only the bot’s owner and admins can edit it.")
          return
        }
        presented = Presented(kind: kind, bot: bot)
      } catch {
        log.error("Failed to load bot \(botUserID) for editing", error: error)
        ToastCenter.shared.showError("Couldn’t load the bot. Try again.")
      }
    }
  }

  func presentations() -> some ViewModifier {
    OwnedBotEditorPresentations(presenter: self)
  }
}

private struct OwnedBotEditorPresentations: ViewModifier {
  @Bindable var presenter: OwnedBotEditorPresenter

  func body(content: Content) -> some View {
    content.sheet(item: $presenter.presented) { item in
      switch item.kind {
      case .profile:
        BotProfileEditorSheet(bot: item.bot) { _ in }
      case .settings:
        OwnedBotSettingsSheet(bot: item.bot)
      }
    }
  }
}
