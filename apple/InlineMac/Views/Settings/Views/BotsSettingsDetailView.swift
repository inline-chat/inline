import AppKit
import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import SwiftUI

struct BotsSettingsDetailView: View {
  @Environment(\.auth) private var auth
  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var viewModel = BotsSettingsViewModel()
  @State private var name = ""
  @State private var username = ""
  @FocusState private var focusedField: Field?

  @State private var botToEdit: BotEditItem?
  @State private var rotateConfirmBotId: Int64?

  var body: some View {
    Form {
      Section("Create Bot") {
        TextField("Name", text: $name)
          .focused($focusedField, equals: .name)

        TextField("Username", text: $username)
          .focused($focusedField, equals: .username)

        Text("Usernames must end with \"bot\" (case-insensitive). You can create up to 5 bots.")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 12) {
          Button(viewModel.isCreating ? "Creating..." : "Create Bot") {
            createBot()
          }
          .disabled(!canCreate)

          if viewModel.isCreating {
            ProgressView()
              .controlSize(.small)
          }
        }

        if let createError = viewModel.createError {
          Text(createError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        if let token = viewModel.lastCreatedToken {
          TokenRow(
            title: "New Token",
            token: token,
            onCopy: { copyToken(token) },
            onHide: { viewModel.clearLastCreatedToken() }
          )
        }
      }

      Section("Your Bots") {
        HStack(spacing: 12) {
          Button("Refresh") {
            Task {
              await viewModel.loadBots(
                realtimeV2,
                currentUserId: auth.currentUserId,
                force: true
              )
            }
          }
          .disabled(viewModel.isLoading)

          if viewModel.isLoading {
            ProgressView()
              .controlSize(.small)
          }
        }

        if let loadError = viewModel.loadError {
          Text(loadError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        if let revealError = viewModel.revealError {
          Text(revealError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        if let rotateError = viewModel.rotateError {
          Text(rotateError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        if viewModel.bots.isEmpty, !viewModel.isLoading {
          Text("No bots yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(viewModel.bots, id: \.id) { bot in
            BotRow(
              bot: bot,
              token: viewModel.revealedTokens[bot.id],
              isRevealing: viewModel.revealingBots.contains(bot.id),
              isRotating: viewModel.rotatingBots.contains(bot.id),
              onReveal: {
                Task { await viewModel.revealToken(for: bot.id, realtimeV2: realtimeV2) }
              },
              onHide: {
                viewModel.hideToken(for: bot.id)
              },
              onRotateRequested: {
                rotateConfirmBotId = bot.id
              },
              onEditProfile: {
                botToEdit = BotEditItem(bot: bot)
              },
              onCopy: { token in
                copyToken(token)
              }
            )
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .task(id: auth.currentUserId) {
      await viewModel.loadBots(
        realtimeV2,
        currentUserId: auth.currentUserId,
        force: false
      )
    }
    .sheet(item: $botToEdit) { item in
      BotProfileEditorSheet(bot: item.bot) { updatedBot in
        viewModel.upsertBot(updatedBot)
      }
    }
    .confirmationDialog(
      "Rotate Token",
      isPresented: .init(
        get: { rotateConfirmBotId != nil },
        set: { if !$0 { rotateConfirmBotId = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Rotate Token", role: .destructive) {
        guard let botId = rotateConfirmBotId else { return }
        rotateConfirmBotId = nil
        Task {
          await viewModel.rotateToken(for: botId, realtimeV2: realtimeV2)
        }
      }
      Button("Cancel", role: .cancel) {
        rotateConfirmBotId = nil
      }
    } message: {
      Text("This will revoke the existing token. Any integrations using the old token will stop working until updated.")
    }
  }

  private var canCreate: Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedUsername = sanitizedUsername(username)
    guard !trimmedName.isEmpty, !trimmedUsername.isEmpty else { return false }
    guard trimmedUsername.lowercased().hasSuffix("bot") else { return false }
    guard viewModel.bots.count < viewModel.maxBots else { return false }
    return !viewModel.isCreating
  }

  private func createBot() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedUsername = sanitizedUsername(username)
    guard !trimmedName.isEmpty, !trimmedUsername.isEmpty else { return }

    Task {
      let created = await viewModel.createBot(
        name: trimmedName,
        username: trimmedUsername,
        realtimeV2: realtimeV2
      )

      if created {
        name = ""
        username = ""
        focusedField = .name
      }
    }
  }

  private func sanitizedUsername(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("@") {
      return String(trimmed.dropFirst())
    }
    return trimmed
  }

  private func copyToken(_ token: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(token, forType: .string)
  }
}

private struct BotEditItem: Identifiable {
  let bot: InlineProtocol.User
  var id: Int64 { bot.id }
}

private enum Field: Hashable {
  case name
  case username
}

@MainActor
final class BotsSettingsViewModel: ObservableObject {
  @Published var bots: [InlineProtocol.User] = []
  @Published var isLoading = false
  @Published var loadError: String?
  @Published var isCreating = false
  @Published var createError: String?
  @Published var revealedTokens: [Int64: String] = [:]
  @Published var revealingBots: Set<Int64> = []
  @Published var lastCreatedToken: String?
  @Published var revealError: String?
  @Published var rotatingBots: Set<Int64> = []
  @Published var rotateError: String?

  let maxBots = 5

  private var hasLoaded = false
  private var lastLoadedUserId: Int64?
  private let log = Log.scoped("BotsSettings")

  func loadBots(
    _ realtimeV2: RealtimeV2,
    currentUserId: Int64?,
    force: Bool
  ) async {
    guard currentUserId != nil else {
      bots = []
      revealedTokens = [:]
      hasLoaded = false
      lastLoadedUserId = nil
      return
    }
    if !force, hasLoaded, lastLoadedUserId == currentUserId {
      return
    }
    guard !isLoading else { return }

    isLoading = true
    loadError = nil
    lastLoadedUserId = currentUserId

    do {
      let result = try await realtimeV2.send(.listBots())
      guard case let .listBots(response) = result else {
        throw TransactionExecutionError.invalid
      }

      bots = response.bots
      let validIds = Set(bots.map(\.id))
      revealedTokens = revealedTokens.filter { validIds.contains($0.key) }
      hasLoaded = true
    } catch {
      log.error("Failed to load bots", error: error)
      loadError = "Failed to load bots."
    }

    isLoading = false
  }

  func createBot(name: String, username: String, realtimeV2: RealtimeV2) async -> Bool {
    guard !isCreating else { return false }

    isCreating = true
    createError = nil
    loadError = nil
    revealError = nil
    rotateError = nil
    lastCreatedToken = nil

    do {
      let result = try await realtimeV2.send(.createBot(name: name, username: username))
      guard case let .createBot(response) = result else {
        throw TransactionExecutionError.invalid
      }

      if response.hasBot {
        bots.append(response.bot)
        bots.sort { $0.id < $1.id }
        if !response.token.isEmpty {
          revealedTokens[response.bot.id] = response.token
          lastCreatedToken = response.token
        }
      }

      isCreating = false
      return true
    } catch {
      log.error("Failed to create bot", error: error)
      createError = "Failed to create bot."
      isCreating = false
      return false
    }
  }

  func revealToken(for botId: Int64, realtimeV2: RealtimeV2) async {
    guard revealingBots.contains(botId) == false else { return }

    revealingBots.insert(botId)
    revealError = nil
    rotateError = nil

    do {
      let result = try await realtimeV2.send(.revealBotToken(botUserId: botId))
      guard case let .revealBotToken(response) = result else {
        throw TransactionExecutionError.invalid
      }

      revealedTokens[botId] = response.token
    } catch {
      log.error("Failed to reveal bot token", error: error)
      revealError = "Failed to reveal token."
    }

    revealingBots.remove(botId)
  }

  func rotateToken(for botId: Int64, realtimeV2: RealtimeV2) async {
    guard rotatingBots.contains(botId) == false else { return }

    rotatingBots.insert(botId)
    rotateError = nil
    revealError = nil

    do {
      let result = try await realtimeV2.send(.rotateBotToken(botUserId: botId))
      guard case let .rotateBotToken(response) = result else {
        throw TransactionExecutionError.invalid
      }

      revealedTokens[botId] = response.token
    } catch {
      log.error("Failed to rotate bot token", error: error)
      rotateError = "Failed to rotate token."
    }

    rotatingBots.remove(botId)
  }

  func hideToken(for botId: Int64) {
    revealedTokens[botId] = nil
  }

  func clearLastCreatedToken() {
    lastCreatedToken = nil
  }

  func upsertBot(_ bot: InlineProtocol.User) {
    if let idx = bots.firstIndex(where: { $0.id == bot.id }) {
      bots[idx] = bot
    } else {
      bots.append(bot)
      bots.sort { $0.id < $1.id }
    }
  }
}

private struct BotRow: View {
  let bot: InlineProtocol.User
  let token: String?
  let isRevealing: Bool
  let isRotating: Bool
  let onReveal: () -> Void
  let onHide: () -> Void
  let onRotateRequested: () -> Void
  let onEditProfile: () -> Void
  let onCopy: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        actionsMenu

        VStack(alignment: .leading, spacing: 2) {
          Text(displayName)
            .font(.body)
          if let username = usernameText {
            Text(username)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }

      if let token {
        TokenRow(
          title: "Token",
          token: token,
          onCopy: { onCopy(token) },
          onHide: onHide
        )
      }
    }
    .padding(.vertical, 4)
  }

  private var actionsMenu: some View {
    Menu {
      if token == nil {
        Button(isRevealing ? "Revealing..." : "Reveal Token") {
          onReveal()
        }
        .disabled(isRevealing)
      } else {
        Button("Hide Token") {
          onHide()
        }
      }

      Divider()

      Button(isRotating ? "Rotating..." : "Rotate Token...") {
        onRotateRequested()
      }
      .disabled(isRotating)

      Button("Edit Profile...") {
        onEditProfile()
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .foregroundStyle(.secondary)
        .contentShape(.circle)
        .frame(width: 18, height: 18)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityLabel("Bot actions")
  }

  private var displayName: String {
    let user = User(from: bot)
    return user.displayName
  }

  private var usernameText: String? {
    guard bot.hasUsername, !bot.username.isEmpty else { return nil }
    return "@\(bot.username)"
  }
}

private struct TokenRow: View {
  let title: String
  let token: String
  let onCopy: () -> Void
  let onHide: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(token)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)

      Spacer()

      Button("Copy") {
        onCopy()
      }

      Button("Hide") {
        onHide()
      }
    }
    .padding(.vertical, 2)
  }
}

#Preview {
  BotsSettingsDetailView()
}
