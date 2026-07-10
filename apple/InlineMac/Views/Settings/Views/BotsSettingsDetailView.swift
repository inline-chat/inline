import AppKit
import InlineKit
import InlineProtocol
import InlineUI
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
  @State private var botToEditAvatar: BotAvatarEditItem?
  @State private var rotateConfirmBotId: Int64?
  @State private var deleteConfirmBot: BotDeleteItem?

  var body: some View {
    Form {
      Section {
        LabeledContent("Name") {
          TextField("Bot Name", text: $name, prompt: Text("Bot Name"))
            .focused($focusedField, equals: .name)
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 280, alignment: .trailing)
        }

        LabeledContent("Username") {
          TextField("Bot Username", text: $username, prompt: Text("username_bot"))
            .focused($focusedField, equals: .username)
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 280, alignment: .trailing)
            .onSubmit {
              if canCreate {
                createBot()
              }
            }
        }

        if let createError = viewModel.createError {
          SettingsErrorRow("Could Not Create Bot", message: createError)
        }

        HStack(spacing: 8) {
          if viewModel.isCreating {
            ProgressView()
              .controlSize(.small)
          }

          Button(viewModel.isCreating ? "Creating..." : "Create Bot") {
            createBot()
          }
          .disabled(!canCreate)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      } header: {
        SettingsSectionHeader(
          "Create Bot",
          subtitle: "Create up to five bots for integrations and automated workflows."
        )
      } footer: {
        Text("Usernames must end with “bot” and are not case-sensitive.")
      }

      Section {
        if let loadError = viewModel.loadError {
          SettingsErrorRow(
            "Could Not Load Bots",
            message: loadError,
            actionTitle: "Try Again",
            action: refreshBots
          )
        }

        if let revealError = viewModel.revealError {
          SettingsErrorRow("Could Not Reveal Token", message: revealError)
        }

        if let rotateError = viewModel.rotateError {
          SettingsErrorRow("Could Not Rotate Token", message: rotateError)
        }

        if let deleteError = viewModel.deleteError {
          SettingsErrorRow("Could Not Delete Bot", message: deleteError)
        }

        if viewModel.isLoading, viewModel.bots.isEmpty {
          SettingsLoadingRow(
            "Loading Bots",
            description: "Fetching bots connected to your account."
          )
        } else if viewModel.bots.isEmpty, viewModel.loadError == nil {
          SettingsEmptyRow(
            "No Bots Yet",
            description: "Create a bot to get started.",
            systemImage: "cpu"
          )
        } else {
          ForEach(viewModel.bots, id: \.id) { bot in
            BotRow(
              bot: bot,
              token: viewModel.revealedTokens[bot.id],
              isRevealing: viewModel.revealingBots.contains(bot.id),
              isRotating: viewModel.rotatingBots.contains(bot.id),
              isDeleting: viewModel.deletingBots.contains(bot.id),
              isBusy: viewModel.isBusy(bot.id),
              onReveal: {
                Task { await viewModel.revealToken(for: bot.id, realtimeV2: realtimeV2) }
              },
              onHide: {
                viewModel.hideToken(for: bot.id)
              },
              onRotateRequested: {
                rotateConfirmBotId = bot.id
              },
              onDeleteRequested: {
                deleteConfirmBot = BotDeleteItem(bot: bot)
              },
              onEditProfile: {
                botToEdit = BotEditItem(bot: bot)
              },
              onEditAvatar: {
                botToEditAvatar = BotAvatarEditItem(bot: bot)
              },
              onCopy: { token in
                copyToken(token)
              }
            )
          }
        }
      } header: {
        SettingsSectionHeader(
          "Your Bots",
          subtitle: "Manage bots used by integrations and automated workflows."
        )
      }
    }
    .settingsFormStyle()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          refreshBots()
        } label: {
          Label("Refresh Bots", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .disabled(viewModel.isLoading)
        .help("Refresh Bots")
      }
    }
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
    .sheet(item: $botToEditAvatar) { item in
      BotAvatarSettingsSheet(bot: item.bot) { updatedBot in
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
    .confirmationDialog(
      "Delete Bot",
      isPresented: .init(
        get: { deleteConfirmBot != nil },
        set: { if !$0 { deleteConfirmBot = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Bot", role: .destructive) {
        guard let bot = deleteConfirmBot else { return }
        deleteConfirmBot = nil
        Task {
          await viewModel.deleteBot(for: bot.id, realtimeV2: realtimeV2)
        }
      }
      Button("Cancel", role: .cancel) {
        deleteConfirmBot = nil
      }
    } message: {
      if let bot = deleteConfirmBot {
        Text("This will delete \(bot.displayName), revoke its token, and hide it from your bot list. Existing messages stay in history.")
      }
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

  private func refreshBots() {
    Task {
      await viewModel.loadBots(
        realtimeV2,
        currentUserId: auth.currentUserId,
        force: true
      )
    }
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

private struct BotAvatarEditItem: Identifiable {
  let bot: InlineProtocol.User
  var id: Int64 { bot.id }
}

private struct BotDeleteItem: Identifiable {
  let id: Int64
  let displayName: String

  init(bot: InlineProtocol.User) {
    id = bot.id
    displayName = User(from: bot).displayName
  }
}

private enum Field: Hashable {
  case name
  case username
}

@MainActor
final class BotsSettingsViewModel: ObservableObject {
  @Published private(set) var bots: [InlineProtocol.User] = []
  @Published private(set) var isLoading = false
  @Published private(set) var loadError: String?
  @Published private(set) var isCreating = false
  @Published private(set) var createError: String?
  @Published private(set) var revealedTokens: [Int64: String] = [:]
  @Published private(set) var revealingBots: Set<Int64> = []
  @Published private(set) var revealError: String?
  @Published private(set) var rotatingBots: Set<Int64> = []
  @Published private(set) var rotateError: String?
  @Published private(set) var deletingBots: Set<Int64> = []
  @Published private(set) var deleteError: String?

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
      deletingBots = []
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
      deletingBots = deletingBots.filter { validIds.contains($0) }
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
    deleteError = nil

    do {
      let result = try await realtimeV2.send(.createBot(name: name, username: username))
      guard case let .createBot(response) = result else {
        throw TransactionExecutionError.invalid
      }

      guard response.hasBot else {
        throw TransactionExecutionError.invalid
      }

      bots.append(response.bot)
      bots.sort { $0.id < $1.id }
      if !response.token.isEmpty {
        revealedTokens[response.bot.id] = response.token
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
    guard !isBusy(botId) else { return }

    revealingBots.insert(botId)
    defer { revealingBots.remove(botId) }
    revealError = nil
    rotateError = nil
    deleteError = nil

    do {
      let result = try await realtimeV2.send(.revealBotToken(botUserId: botId))
      guard case let .revealBotToken(response) = result else {
        throw TransactionExecutionError.invalid
      }
      guard !response.token.isEmpty else {
        throw TransactionExecutionError.invalid
      }

      revealedTokens[botId] = response.token
    } catch {
      log.error("Failed to reveal bot token", error: error)
      revealError = "Failed to reveal token."
    }
  }

  func rotateToken(for botId: Int64, realtimeV2: RealtimeV2) async {
    guard !isBusy(botId) else { return }

    rotatingBots.insert(botId)
    defer { rotatingBots.remove(botId) }
    rotateError = nil
    revealError = nil
    deleteError = nil

    do {
      let result = try await realtimeV2.send(.rotateBotToken(botUserId: botId))
      guard case let .rotateBotToken(response) = result else {
        throw TransactionExecutionError.invalid
      }
      guard !response.token.isEmpty else {
        revealedTokens[botId] = nil
        throw TransactionExecutionError.invalid
      }

      revealedTokens[botId] = response.token
    } catch {
      log.error("Failed to rotate bot token", error: error)
      rotateError = "Failed to rotate token."
    }
  }

  func deleteBot(for botId: Int64, realtimeV2: RealtimeV2) async {
    guard !isBusy(botId) else { return }

    deletingBots.insert(botId)
    deleteError = nil
    revealError = nil
    rotateError = nil
    defer {
      deletingBots.remove(botId)
    }

    do {
      let result = try await realtimeV2.send(.deleteBot(botUserId: botId))
      guard case .deleteBot = result else {
        throw TransactionExecutionError.invalid
      }

      bots.removeAll { $0.id == botId }
      revealedTokens[botId] = nil
    } catch {
      log.error("Failed to delete bot", error: error)
      deleteError = "Failed to delete bot."
    }
  }

  func hideToken(for botId: Int64) {
    revealedTokens[botId] = nil
  }

  func isBusy(_ botId: Int64) -> Bool {
    revealingBots.contains(botId)
      || rotatingBots.contains(botId)
      || deletingBots.contains(botId)
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
  let isDeleting: Bool
  let isBusy: Bool
  let onReveal: () -> Void
  let onHide: () -> Void
  let onRotateRequested: () -> Void
  let onDeleteRequested: () -> Void
  let onEditProfile: () -> Void
  let onEditAvatar: () -> Void
  let onCopy: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        UserAvatar(user: User(from: bot), size: 32)

        VStack(alignment: .leading, spacing: 2) {
          Text(displayName)
            .font(.body)
            .fontWeight(.medium)
          if let username = usernameText {
            Text(username)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if isRevealing || isRotating || isDeleting {
          ProgressView()
            .controlSize(.small)
        }

        actionsMenu
      }

      if let token {
        TokenRow(
          title: "Token",
          token: token,
          onCopy: { onCopy(token) },
          onHide: onHide
        )
        .padding(.leading, 42)
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

      Button("Bot Avatar...") {
        onEditAvatar()
      }

      Divider()

      Button(isDeleting ? "Deleting..." : "Delete Bot...") {
        onDeleteRequested()
      }
      .disabled(isDeleting)
    } label: {
      Image(systemName: "ellipsis.circle")
        .foregroundStyle(.secondary)
        .contentShape(.circle)
        .frame(width: 18, height: 18)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .disabled(isBusy)
    .accessibilityLabel("Actions for \(displayName)")
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
        .frame(maxWidth: .infinity, alignment: .leading)

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
