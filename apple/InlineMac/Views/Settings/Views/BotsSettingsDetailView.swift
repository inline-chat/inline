import AppKit
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct BotsSettingsDetailView: View {
  @Environment(\.auth) private var auth
  @Environment(\.dependencies) private var dependencies
  @Environment(\.realtimeV2) private var realtimeV2
  @AppStorage(ExperimentalFeatureFlags.mentionableAgentsKey)
  private var mentionableAgentsEnabled = false

  @StateObject private var viewModel = BotsSettingsViewModel()
  @State private var name = ""
  @State private var username = ""
  @FocusState private var focusedField: Field?

  @State private var botToEdit: BotEditItem?
  @State private var botToEditAvatar: BotAvatarEditItem?
  @State private var botSettingsItem: BotSettingsItem?
  @State private var rotateConfirmBotId: Int64?
  @State private var deleteConfirmBot: BotDeleteItem?

  private let log = Log.scoped("BotsSettings")

  var body: some View {
    Form {
      Section {
        LabeledContent("Inline CLI") {
          Button("Install or Update…") {
            AppMenu.shared.installCLI()
          }
          .disabled(dependencies == nil || dependencies?.cliInstaller.phase.isBusy == true)
        }

        LabeledContent("Agent Harness") {
          Button("Set Up Agent…") {
            guard let dependencies else { return }
            AgentSetupWindowController.show(using: dependencies)
          }
          .disabled(dependencies == nil)
        }
      } header: {
        SettingsSectionHeader(
          "Agent Setup",
          subtitle: "Install Inline’s CLI and connect Codex, Claude, OpenCode, Amp, Hermes, or OpenClaw."
        )
      }

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
              onOpen: {
                Task { await openBot(bot) }
              },
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
              onSettings: {
                botSettingsItem = BotSettingsItem(bot: bot)
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

      if mentionableAgentsEnabled {
        MacBotAgentsSection(bots: viewModel.bots)
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
    .sheet(item: $botSettingsItem) { item in
      ManagedBotSettingsSheet(
        bot: item.bot,
        token: viewModel.revealedTokens[item.id],
        isBusy: viewModel.isBusy(item.id),
        onRevealToken: {
          Task { await viewModel.revealToken(for: item.id, realtimeV2: realtimeV2) }
        },
        onHideToken: {
          viewModel.hideToken(for: item.id)
        },
        onCopyToken: copyToken,
        onRotateToken: {
          Task { await viewModel.rotateToken(for: item.id, realtimeV2: realtimeV2) }
        },
        onBotUpdated: { updatedBot in
          viewModel.upsertBot(updatedBot)
          botSettingsItem = BotSettingsItem(bot: updatedBot)
        }
      )
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
      guard let createdBot = await viewModel.createBot(
        name: trimmedName,
        username: trimmedUsername,
        realtimeV2: realtimeV2
      ) else { return }

      name = ""
      username = ""
      focusedField = .name
      await openBot(createdBot)
    }
  }

  private func openBot(_ bot: InlineProtocol.User) async {
    let peer = Peer.user(id: bot.id)

    do {
      _ = try await realtimeV2.send(.getChat(peer: peer))
      _ = try await realtimeV2.send(.updateDialogOpen(peerId: peer, open: true))
      MainWindowOpenCoordinator.shared.openWindow(.chat(peer: peer))
    } catch {
      log.error("Failed to open bot chat", error: error)
      dependencies?.overlay.showError(message: "The bot was saved, but its chat could not be opened.")
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

private struct BotSettingsItem: Identifiable {
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
      await saveBotsLocally(response.bots)
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

  func createBot(name: String, username: String, realtimeV2: RealtimeV2) async -> InlineProtocol.User? {
    guard !isCreating else { return nil }

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

      await saveBotsLocally([response.bot])
      bots.append(response.bot)
      bots.sort { $0.id < $1.id }
      if !response.token.isEmpty {
        revealedTokens[response.bot.id] = response.token
      }

      isCreating = false
      return response.bot
    } catch {
      log.error("Failed to create bot", error: error)
      createError = "Failed to create bot."
      isCreating = false
      return nil
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

  private func saveBotsLocally(_ bots: [InlineProtocol.User]) async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        for bot in bots {
          _ = try User.save(db, user: bot)
        }
      }
    } catch {
      log.error("Failed to save managed bots locally", error: error)
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
  let onOpen: () -> Void
  let onReveal: () -> Void
  let onHide: () -> Void
  let onRotateRequested: () -> Void
  let onDeleteRequested: () -> Void
  let onEditProfile: () -> Void
  let onEditAvatar: () -> Void
  let onSettings: () -> Void
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
      Button("Open Chat") {
        onOpen()
      }

      Divider()

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

      Button("Settings...") {
        onSettings()
      }

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

      Button(isDeleting ? "Deleting..." : "Delete Bot...", role: .destructive) {
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

private struct ManagedBotSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var botToEdit: BotEditItem?
  @State private var botToEditAvatar: BotAvatarEditItem?
  @State private var isConfirmingRotation = false

  let bot: InlineProtocol.User
  let token: String?
  let isBusy: Bool
  let onRevealToken: () -> Void
  let onHideToken: () -> Void
  let onCopyToken: (String) -> Void
  let onRotateToken: () -> Void
  let onBotUpdated: (InlineProtocol.User) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Form {
        ManagedBotIdentitySection(
          bot: bot,
          onEditProfile: { botToEdit = BotEditItem(bot: bot) },
          onEditAvatar: { botToEditAvatar = BotAvatarEditItem(bot: bot) }
        )
        ManagedBotAccessSection(
          token: token,
          isBusy: isBusy,
          onRevealToken: onRevealToken,
          onHideToken: onHideToken,
          onCopyToken: onCopyToken,
          onRotateToken: { isConfirmingRotation = true }
        )
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 560, height: 620)
    .sheet(item: $botToEdit) { item in
      BotProfileEditorSheet(bot: item.bot, onUpdated: onBotUpdated)
    }
    .sheet(item: $botToEditAvatar) { item in
      BotAvatarSettingsSheet(bot: item.bot, onUpdated: onBotUpdated)
    }
    .confirmationDialog(
      "Rotate Token",
      isPresented: $isConfirmingRotation,
      titleVisibility: .visible
    ) {
      Button("Rotate Token", role: .destructive, action: onRotateToken)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will revoke the existing token. Any integrations using the old token will stop working until updated.")
    }
  }
}

private struct MacBotAgentRow: Identifiable {
  let bot: InlineProtocol.User
  let agent: InlineProtocol.BotAgent

  var id: Int64 { agent.id }
}

private struct MacBotAgentsSection: View {
  let bots: [InlineProtocol.User]

  @State private var models: [Int64: BotAgentsSettingsModel] = [:]
  @State private var editorItem: MacBotAgentEditorItem?
  @State private var agentToDelete: MacBotAgentRow?

  private var rows: [MacBotAgentRow] {
    bots.flatMap { bot in
      (models[bot.id]?.agents ?? []).map { MacBotAgentRow(bot: bot, agent: $0) }
    }
  }

  private var isLoading: Bool {
    models.values.contains { $0.isLoading }
  }

  private var skillCatalogs: [Int64: [InlineProtocol.BotSkill]] {
    models.mapValues(\.skills)
  }

  var body: some View {
    Section {
      if bots.isEmpty {
        Text("Create a bot before adding a Skilled Agent.")
          .foregroundStyle(.secondary)
      } else if isLoading, rows.isEmpty {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading Skilled Agents...")
            .foregroundStyle(.secondary)
        }
      } else if rows.isEmpty {
        Text("No Skilled Agents yet. Create a named specialization people can @mention wherever its bot has access.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(rows) { row in
          MacBotAgentRowView(
            bot: row.bot,
            agent: row.agent,
            isDeleting: models[row.bot.id]?.deletingAgentIds.contains(row.agent.id) == true,
            onEdit: {
              editorItem = MacBotAgentEditorItem(botUserId: row.bot.id, agent: row.agent)
            },
            onDelete: { agentToDelete = row }
          )
        }
      }

      ForEach(bots, id: \.id) { bot in
        if let errorMessage = models[bot.id]?.errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      HStack {
        Spacer()
        Button {
          guard let bot = bots.first else { return }
          editorItem = MacBotAgentEditorItem(botUserId: bot.id, agent: nil)
        } label: {
          Label("New Skilled Agent...", systemImage: "plus")
        }
        .disabled(bots.isEmpty)
      }
    } header: {
      SettingsSectionHeader(
        "Skilled Agents",
        subtitle: "Create mentionable specializations on your existing bots and harnesses."
      )
    } footer: {
      Text("Skill and instructions are independently optional. Skilled Agents reuse the selected bot’s identity, credentials, memory, skills, and chat access.")
    }
    .task(id: bots.map(\.id)) {
      await synchronizeModels()
    }
    .sheet(item: $editorItem) { item in
      MacBotAgentEditor(
        item: item,
        bots: bots,
        skillCatalogs: skillCatalogs,
        onSave: { botUserId, draft in
          guard let model = models[botUserId] else { return false }
          return await model.save(draft, agentId: item.agent?.id)
        }
      )
    }
    .confirmationDialog(
      "Delete Skilled Agent",
      isPresented: .init(
        get: { agentToDelete != nil },
        set: { if !$0 { agentToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Skilled Agent", role: .destructive) {
        guard let row = agentToDelete, let model = models[row.bot.id] else { return }
        agentToDelete = nil
        Task { await model.delete(agentId: row.agent.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Existing messages keep their text, but future mentions will no longer activate this specialization.")
    }
  }

  private func synchronizeModels() async {
    let validIds = Set(bots.map(\.id))
    models = models.filter { validIds.contains($0.key) }
    for bot in bots where models[bot.id] == nil {
      models[bot.id] = BotAgentsSettingsModel(botUserId: bot.id)
    }
    for bot in bots {
      await models[bot.id]?.load()
    }
  }
}

private struct MacBotAgentRowView: View {
  let bot: InlineProtocol.User
  let agent: InlineProtocol.BotAgent
  let isDeleting: Bool
  let onEdit: () -> Void
  let onDelete: () -> Void

  private var botUser: User { User(from: bot) }

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(user: botUser, size: 30)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 5) {
          if agent.hasEmoji, !agent.emoji.isEmpty {
            Text(agent.emoji)
          }
          Text(agent.name)
            .fontWeight(.medium)
        }
        Text("via \(botUser.displayName)")
          .font(.caption)
          .foregroundStyle(.secondary)
        if agent.hasDescription_p, !agent.description_p.isEmpty {
          Text(agent.description_p)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if isDeleting {
        ProgressView().controlSize(.small)
      } else {
        Button("Edit...", action: onEdit)
        Button(role: .destructive, action: onDelete) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete Skilled Agent")
        .help("Delete Skilled Agent")
      }
    }
  }
}

private struct MacBotAgentEditorItem: Identifiable {
  let botUserId: Int64
  let agent: InlineProtocol.BotAgent?
  let id = UUID()
}

private struct MacBotAgentEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: ManagedBotAgentDraft
  @State private var selectedBotUserId: Int64
  @State private var isSaving = false

  let item: MacBotAgentEditorItem
  let bots: [InlineProtocol.User]
  let skillCatalogs: [Int64: [InlineProtocol.BotSkill]]
  let onSave: (Int64, ManagedBotAgentDraft) async -> Bool

  init(
    item: MacBotAgentEditorItem,
    bots: [InlineProtocol.User],
    skillCatalogs: [Int64: [InlineProtocol.BotSkill]],
    onSave: @escaping (Int64, ManagedBotAgentDraft) async -> Bool
  ) {
    self.item = item
    self.bots = bots
    self.skillCatalogs = skillCatalogs
    self.onSave = onSave
    _selectedBotUserId = State(initialValue: item.botUserId)
    _draft = State(initialValue: item.agent.map { ManagedBotAgentDraft(agent: $0) } ?? ManagedBotAgentDraft())
  }

  private var selectedSkills: [InlineProtocol.BotSkill] {
    skillCatalogs[selectedBotUserId] ?? []
  }

  private var hasUnavailableSkill: Bool {
    !draft.skillKey.isEmpty && !selectedSkills.contains { $0.key == draft.skillKey }
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Identity") {
          LabeledContent("Name") {
            TextField("Data Analyst", text: $draft.name)
              .frame(width: 320)
          }
          LabeledContent("Handle (Optional)") {
            TextField("data-analyst", text: $draft.handle)
              .frame(width: 320)
          }
          LabeledContent("Emoji (Optional)") {
            TextField("📊", text: $draft.emoji)
              .frame(width: 320)
          }
          LabeledContent("Description (Optional)") {
            TextField("What this Skilled Agent is for", text: $draft.description)
              .frame(width: 320)
          }
        }

        Section {
          Picker("Harness", selection: $selectedBotUserId) {
            ForEach(bots, id: \.id) { bot in
              Text(User(from: bot).displayName).tag(bot.id)
            }
          }
          .disabled(item.agent != nil)
          .onChange(of: selectedBotUserId) { _, _ in
            if item.agent == nil {
              draft.skillKey = ""
            }
          }

          Picker("Skill (Optional)", selection: $draft.skillKey) {
            Text("No Skill").tag("")
            if hasUnavailableSkill {
              Text("Unavailable: \(draft.skillKey)").tag(draft.skillKey)
            }
            ForEach(selectedSkills, id: \.key) { skill in
              Text(skill.name).tag(skill.key)
            }
          }

          LabeledContent("Instructions (Optional)") {
            TextEditor(text: $draft.instructions)
              .font(.body)
              .frame(width: 320, height: 120)
              .overlay {
                RoundedRectangle(cornerRadius: 5)
                  .stroke(.secondary.opacity(0.25), lineWidth: 1)
              }
          }
        } header: {
          Text("Specialization")
        } footer: {
          Text("Choose a skill, add instructions, use both, or leave both empty. A name-only Skilled Agent receives a minimal specialization instruction.")
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(isSaving ? "Saving..." : "Save") {
          isSaving = true
          Task {
            if await onSave(selectedBotUserId, draft) {
              dismiss()
            }
            isSaving = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedBotUserId == 0
            || isSaving
        )
      }
      .padding()
    }
    .frame(width: 580, height: 640)
  }
}

private struct ManagedBotIdentitySection: View {
  let bot: InlineProtocol.User
  let onEditProfile: () -> Void
  let onEditAvatar: () -> Void

  var body: some View {
    Section("Profile") {
      LabeledContent("Name", value: User(from: bot).displayName)
      if bot.hasUsername, !bot.username.isEmpty {
        LabeledContent("Username", value: "@\(bot.username)")
      }
      HStack {
        Button("Edit Profile...", action: onEditProfile)
        Button("Change Avatar...", action: onEditAvatar)
      }
    }
  }
}

private struct ManagedBotAccessSection: View {
  let token: String?
  let isBusy: Bool
  let onRevealToken: () -> Void
  let onHideToken: () -> Void
  let onCopyToken: (String) -> Void
  let onRotateToken: () -> Void

  var body: some View {
    Section {
      if let token {
        Text(token)
          .font(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .privacySensitive()
          .textSelection(.enabled)

        HStack {
          Button("Copy") { onCopyToken(token) }
          Button("Hide", action: onHideToken)
        }
      } else {
        Button("Reveal Token", action: onRevealToken)
          .disabled(isBusy)
      }

      Button("Rotate Token...", action: onRotateToken)
        .disabled(isBusy)
    } header: {
      Text("Access Token")
    } footer: {
      Text("Keep this token private. Rotating it immediately revokes the previous token.")
    }
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
