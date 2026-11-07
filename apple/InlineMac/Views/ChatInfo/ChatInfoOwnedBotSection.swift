import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import SwiftUI

/// Profile and settings shortcuts for a bot the viewer owns, in its chat info.
/// Renders nothing for other people's bots.
struct ChatInfoOwnedBotSection: View {
  let botUserID: Int64

  @Environment(\.realtimeV2) private var realtimeV2
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var presented: Presented?
  @State private var opening: Presented.Kind?

  private let log = Log.scoped("ChatInfoOwnedBot")

  /// The owner's grant list exists only for their own bots, and stays cached
  /// across chat info openings.
  private var isOwned: Bool {
    grants.ownedGrants(botUserID: botUserID) != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      if isOwned {
        GroupBox {
          VStack(alignment: .leading, spacing: 0) {
            row("Profile", detail: "Photo, name, and username") {
              button("Edit…", kind: .profile)
            }
            Divider()
            row("Bot Settings", detail: "Output, token, and avatar") {
              button("Open…", kind: .settings)
            }
          }
          .padding(.vertical, 4)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
    }
    .sheet(item: $presented) { item in
      switch item.kind {
      case .profile:
        BotProfileEditorSheet(bot: item.bot) { _ in }
      case .settings:
        OwnedBotSettingsSheet(bot: item.bot)
      }
    }
  }

  private func row(
    _ title: String,
    detail: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      content()
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
  }

  private func button(_ title: String, kind: Presented.Kind) -> some View {
    Button(title) { open(kind) }
      .disabled(opening != nil)
      .overlay {
        if opening == kind {
          ProgressView().controlSize(.small)
        }
      }
  }

  /// The editors take the server's bot record, which only the owner's bot list returns.
  private func open(_ kind: Presented.Kind) {
    guard opening == nil else { return }
    opening = kind
    Task { @MainActor in
      defer { opening = nil }
      do {
        let result = try await realtimeV2.send(.listBots())
        guard case let .listBots(response) = result else { throw TransactionExecutionError.invalid }
        guard let bot = response.bots.first(where: { $0.id == botUserID }) else {
          ToastCenter.shared.showError("Only the bot’s owner can edit it.")
          return
        }
        presented = Presented(kind: kind, bot: bot)
      } catch {
        log.error("Failed to load bot \(botUserID) for editing", error: error)
        ToastCenter.shared.showError("Couldn’t load the bot. Try again.")
      }
    }
  }

  private struct Presented: Identifiable {
    enum Kind { case profile, settings }

    let kind: Kind
    let bot: InlineProtocol.User
    var id: String { "\(kind)-\(bot.id)" }
  }
}
