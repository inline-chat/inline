import InlineKit
import InlineProtocol
import InlineUI
import Logger
import MultipartFormDataKit
import RealtimeV2
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BotsSettingsView: View {
  @Environment(\.realtimeV2) private var realtimeV2

  @State private var model = IOSBotsSettingsModel()
  @State private var name = ""
  @State private var username = ""
  @State private var botToDelete: InlineProtocol.User?
  @State private var copiedTokenPasteboardChangeCount: Int?

  var body: some View {
    List {
      Section {
        TextField("Bot Name", text: $name)
          .textContentType(.name)

        HStack(spacing: 2) {
          Text("@", comment: "Fixed prefix shown before an editable bot username.")
            .foregroundStyle(.secondary)
          TextField("username_bot", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        Button {
          createBot()
        } label: {
          if model.isCreating {
            HStack {
              ProgressView()
              Text("Creating Bot…")
            }
          } else {
            Label("Create Bot", systemImage: "plus")
          }
        }
        .disabled(!canCreate)
      } header: {
        Text("Create Bot")
      } footer: {
        Text("Bot usernames must end with “bot”.")
      }

      if let errorMessage = model.errorMessage {
        IOSBotErrorSection(message: errorMessage)
      }

      Section("Your Bots") {
        if model.isLoading, model.bots.isEmpty {
          HStack {
            ProgressView()
            Text("Loading bots…")
              .foregroundStyle(.secondary)
          }
        } else if model.bots.isEmpty {
          ContentUnavailableView(
            "No Bots Yet",
            systemImage: "cpu",
            description: Text("Create a bot for integrations and automated workflows.")
          )
        } else {
          ForEach(model.bots, id: \.id) { bot in
            IOSBotSettingsRow(
              bot: bot,
              token: model.revealedTokens[bot.id],
              isBusy: model.busyBotIDs.contains(bot.id),
              model: model,
              copyToken: copyToken,
              requestDelete: { botToDelete = bot }
            )
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Bots")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable {
      await model.load(realtimeV2)
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await model.load(realtimeV2) }
        } label: {
          Label("Refresh Bots", systemImage: "arrow.clockwise")
        }
        .disabled(model.isLoading)
      }
    }
    .confirmationDialog(
      "Delete Bot?",
      isPresented: Binding(
        get: { botToDelete != nil },
        set: { if !$0 { botToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Bot", role: .destructive) {
        guard let bot = botToDelete else { return }
        botToDelete = nil
        Task { await model.delete(bot.id, realtimeV2: realtimeV2) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This revokes the bot token. Existing messages remain in history.")
    }
    .task {
      await model.load(realtimeV2)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
      clearSensitiveState()
    }
  }

  private var sanitizedUsername: String {
    IOSBotsSettingsModel.sanitizedUsername(username).lowercased()
  }

  private var canCreate: Bool {
    !model.isCreating
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && sanitizedUsername.hasSuffix("bot")
  }

  private func createBot() {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = sanitizedUsername
    guard canCreate else { return }

    Task {
      if await model.create(name: trimmedName, username: candidate, realtimeV2: realtimeV2) {
        name = ""
        username = ""
      }
    }
  }

  private func copyToken(_ token: String) {
    UIPasteboard.general.setItems(
      [[UTType.plainText.identifier: token]],
      options: [
        .localOnly: true,
        .expirationDate: Date().addingTimeInterval(60),
      ]
    )
    copiedTokenPasteboardChangeCount = UIPasteboard.general.changeCount
    ToastManager.shared.showToast(
      "Token copied for 60 seconds",
      type: .success,
      systemImage: "doc.on.doc.fill"
    )
  }

  private func clearSensitiveState() {
    model.hideAllTokens()

    if let copiedTokenPasteboardChangeCount,
       UIPasteboard.general.changeCount == copiedTokenPasteboardChangeCount {
      UIPasteboard.general.items = []
    }
    copiedTokenPasteboardChangeCount = nil
  }
}

@MainActor
@Observable
final class IOSBotsSettingsModel {
  private(set) var bots: [InlineProtocol.User] = []
  private(set) var revealedTokens: [Int64: String] = [:]
  private(set) var busyBotIDs: Set<Int64> = []
  private(set) var isLoading = false
  private(set) var isCreating = false
  var errorMessage: String?

  @ObservationIgnored private let log = Log.scoped("IOSSettings.Bots")

  static func sanitizedUsername(_ value: String) -> String {
    var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("@") {
      value.removeFirst()
    }
    return value
  }

  static func isValidBotUsername(_ value: String) -> Bool {
    value.count >= 2
      && value.count <= 64
      && value.lowercased().hasSuffix("bot")
      && value.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_]*[a-zA-Z0-9]$", options: .regularExpression) != nil
  }

  func bot(_ botID: Int64) -> InlineProtocol.User? {
    bots.first { $0.id == botID }
  }

  func load(_ realtimeV2: RealtimeV2) async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let result = try await realtimeV2.send(.listBots())
      guard case let .listBots(response) = result else {
        throw TransactionExecutionError.invalid
      }
      bots = response.bots.sorted { $0.id < $1.id }
      let validIDs = Set(bots.map(\.id))
      revealedTokens = revealedTokens.filter { validIDs.contains($0.key) }
      await saveLocally(response.bots)
    } catch {
      log.error("Failed to load bots", error: error)
      errorMessage = "Could not load bots. Pull to try again."
    }
  }

  func create(name: String, username: String, realtimeV2: RealtimeV2) async -> Bool {
    guard !isCreating else { return false }
    isCreating = true
    errorMessage = nil
    defer { isCreating = false }

    do {
      let result = try await realtimeV2.send(.createBot(name: name, username: username))
      guard case let .createBot(response) = result, response.hasBot else {
        throw TransactionExecutionError.invalid
      }
      upsert(response.bot)
      if !response.token.isEmpty {
        revealedTokens[response.bot.id] = response.token
      }
      await saveLocally([response.bot])
      return true
    } catch {
      log.error("Failed to create bot", error: error)
      errorMessage = "Could not create the bot. Check the name and username, then try again."
      return false
    }
  }

  func revealToken(_ botID: Int64, realtimeV2: RealtimeV2) async {
    await perform(botID, failure: "Could not reveal the bot token.") {
      let result = try await realtimeV2.send(.revealBotToken(botUserId: botID))
      guard case let .revealBotToken(response) = result, !response.token.isEmpty else {
        throw TransactionExecutionError.invalid
      }
      revealedTokens[botID] = response.token
    }
  }

  func hideToken(_ botID: Int64) {
    revealedTokens[botID] = nil
  }

  func hideAllTokens() {
    revealedTokens.removeAll(keepingCapacity: false)
  }

  func rotateToken(_ botID: Int64, realtimeV2: RealtimeV2) async {
    await perform(botID, failure: "Could not rotate the bot token.") {
      let result = try await realtimeV2.send(.rotateBotToken(botUserId: botID))
      guard case let .rotateBotToken(response) = result, !response.token.isEmpty else {
        revealedTokens[botID] = nil
        throw TransactionExecutionError.invalid
      }
      revealedTokens[botID] = response.token
    }
  }

  @discardableResult
  func delete(_ botID: Int64, realtimeV2: RealtimeV2) async -> Bool {
    await perform(botID, failure: "Could not delete the bot.") {
      let result = try await realtimeV2.send(.deleteBot(botUserId: botID))
      guard case .deleteBot = result else {
        throw TransactionExecutionError.invalid
      }
      bots.removeAll { $0.id == botID }
      revealedTokens[botID] = nil
    }
  }

  /// Sends only the fields that changed. Returns false and sets `errorMessage` on failure.
  func updateProfile(
    _ botID: Int64,
    name: String?,
    username: String?,
    realtimeV2: RealtimeV2
  ) async -> Bool {
    await perform(botID, failure: "Could not update the bot profile.") {
      try await updateBotProfile(botID, name: name, username: username, realtimeV2: realtimeV2)
    }
  }

  func uploadPhoto(_ botID: Int64, image: UIImage, realtimeV2: RealtimeV2) async {
    await perform(botID, failure: "Could not update the bot photo. Try another image.") {
      guard let data = image.jpegData(compressionQuality: 0.86) else {
        throw TransactionExecutionError.invalid
      }
      let upload = try await ApiClient.shared.uploadFile(
        type: .photo,
        data: data,
        filename: "bot-profile-photo.jpg",
        mimeType: .imageJpeg,
        progress: { _ in }
      )
      try await updateBotProfile(botID, photoFileUniqueId: upload.fileUniqueId, realtimeV2: realtimeV2)
    }
  }

  func removePhoto(_ botID: Int64, realtimeV2: RealtimeV2) async {
    await perform(botID, failure: "Could not remove the bot photo.") {
      try await updateBotProfile(botID, photoFileUniqueId: "", realtimeV2: realtimeV2)
    }
  }

  func clearBotAvatar(_ botID: Int64, realtimeV2: RealtimeV2) async {
    await perform(botID, failure: "Could not clear the bot avatar.") {
      let result = try await realtimeV2.send(.clearBotAvatar(botUserId: botID))
      guard case let .clearBotAvatar_p(response) = result else {
        throw TransactionExecutionError.invalid
      }
      upsert(response.bot)
      await saveLocally([response.bot])
    }
  }

  func prepareChat(_ botID: Int64, realtimeV2: RealtimeV2) async -> Bool {
    await perform(botID, failure: "Could not open the bot chat.") {
      let peer = Peer.user(id: botID)
      _ = try await realtimeV2.send(.getChat(peer: peer))
      _ = try await realtimeV2.send(.updateDialogOpen(peerId: peer, open: true))
    }
  }

  private func updateBotProfile(
    _ botID: Int64,
    name: String? = nil,
    photoFileUniqueId: String? = nil,
    username: String? = nil,
    realtimeV2: RealtimeV2
  ) async throws {
    let result = try await realtimeV2.send(.updateBotProfile(
      botUserId: botID,
      name: name,
      photoFileUniqueId: photoFileUniqueId,
      username: username
    ))
    guard case let .updateBotProfile(response) = result else {
      throw TransactionExecutionError.invalid
    }
    upsert(response.bot)
    await saveLocally([response.bot])
  }

  @discardableResult
  private func perform(
    _ botID: Int64,
    failure: String,
    _ operation: () async throws -> Void
  ) async -> Bool {
    guard !busyBotIDs.contains(botID) else { return false }
    busyBotIDs.insert(botID)
    errorMessage = nil
    defer { busyBotIDs.remove(botID) }

    do {
      try await operation()
      return true
    } catch {
      log.error(failure, error: error)
      errorMessage = Self.message(for: error) ?? failure
      return false
    }
  }

  private static func message(for error: Error) -> String? {
    guard case let TransactionError.rpcError(rpcError) = error else { return nil }
    switch rpcError.errorCode {
    case .usernameTaken: return "That username is already taken."
    case .usernameInvalid: return "Usernames use letters, numbers, and underscores, and must end with “bot”."
    default: return nil
    }
  }

  private func upsert(_ bot: InlineProtocol.User) {
    if let index = bots.firstIndex(where: { $0.id == bot.id }) {
      bots[index] = bot
    } else {
      bots.append(bot)
      bots.sort { $0.id < $1.id }
    }
  }

  private func saveLocally(_ bots: [InlineProtocol.User]) async {
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

private struct IOSBotErrorSection: View {
  let message: String

  var body: some View {
    Section {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
  }
}

private struct IOSBotSettingsRow: View {
  @Environment(\.realtimeV2) private var realtimeV2

  let bot: InlineProtocol.User
  let token: String?
  let isBusy: Bool
  let model: IOSBotsSettingsModel
  let copyToken: (String) -> Void
  let requestDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        NavigationLink {
          IOSManagedBotSettingsView(botID: bot.id, model: model, copyToken: copyToken)
        } label: {
          IOSManagedBotSummary(bot: bot)
        }
        .buttonStyle(.plain)

        if isBusy {
          ProgressView()
            .controlSize(.small)
        } else {
          Menu {
            if let token {
              Button("Copy Token") { copyToken(token) }
              Button("Hide Token") { model.hideToken(bot.id) }
            } else {
              Button("Reveal Token") {
                Task { await model.revealToken(bot.id, realtimeV2: realtimeV2) }
              }
            }

            Divider()
            Button("Delete Bot", role: .destructive, action: requestDelete)
          } label: {
            Image(systemName: "ellipsis.circle")
              .foregroundStyle(.secondary)
          }
          .accessibilityLabel("Actions for \(User(from: bot).displayName)")
        }
      }

      if let token {
        HStack(spacing: 8) {
          Text(token)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .privacySensitive()
            .frame(maxWidth: .infinity, alignment: .leading)

          Button("Copy") {
            copyToken(token)
          }
          .buttonStyle(.borderless)
        }
        .padding(.leading, 48)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct IOSManagedBotSummary: View {
  let bot: InlineProtocol.User

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(user: User(from: bot), size: 38)

      VStack(alignment: .leading, spacing: 2) {
        Text(User(from: bot).displayName)
        if bot.hasUsername, !bot.username.isEmpty {
          Text("@\(bot.username)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct IOSManagedBotSettingsView: View {
  @Environment(\.realtimeV2) private var realtimeV2
  @Environment(Router.self) private var router
  @Environment(\.dismiss) private var dismiss

  let botID: Int64
  let model: IOSBotsSettingsModel
  let copyToken: (String) -> Void

  @State private var name: String
  @State private var username: String
  @State private var isConfirmingRotation = false
  @State private var isConfirmingDelete = false
  @State private var showsImagePicker = false
  @State private var showsCropper = false
  @State private var pickedImage: UIImage?

  init(botID: Int64, model: IOSBotsSettingsModel, copyToken: @escaping (String) -> Void) {
    self.botID = botID
    self.model = model
    self.copyToken = copyToken
    let bot = model.bot(botID)
    _name = State(initialValue: bot.map { User(from: $0).displayName } ?? "")
    _username = State(initialValue: bot?.username ?? "")
  }

  var body: some View {
    Group {
      if let bot = model.bot(botID) {
        content(bot)
      } else {
        ContentUnavailableView("Bot Unavailable", systemImage: "cpu")
      }
    }
    .navigationBarTitleDisplayMode(.inline)
  }

  private var isBusy: Bool {
    model.busyBotIDs.contains(botID)
  }

  private func content(_ bot: InlineProtocol.User) -> some View {
    List {
      Section {
        IOSManagedBotPhotoEditor(
          bot: bot,
          isBusy: isBusy,
          choosePhoto: { showsImagePicker = true },
          removePhoto: {
            Task { await model.removePhoto(botID, realtimeV2: realtimeV2) }
          }
        )
      }

      if let errorMessage = model.errorMessage {
        IOSBotErrorSection(message: errorMessage)
      }

      Section {
        TextField("Bot Name", text: $name)
          .textContentType(.name)

        HStack(spacing: 2) {
          Text("@", comment: "Fixed prefix shown before an editable bot username.")
            .foregroundStyle(.secondary)
          TextField("username_bot", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      } header: {
        Text("Profile")
      } footer: {
        Text("Bot usernames must end with “bot”.")
      }

      if bot.hasBotAvatar {
        IOSManagedBotAvatarSection(bot: bot, isBusy: isBusy) {
          Task { await model.clearBotAvatar(botID, realtimeV2: realtimeV2) }
        }
      }

      Section {
        Button {
          openChat()
        } label: {
          Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
        }
        .disabled(isBusy)
      }

      IOSManagedBotAccessSection(
        token: model.revealedTokens[botID],
        isBusy: isBusy,
        revealToken: {
          Task { await model.revealToken(botID, realtimeV2: realtimeV2) }
        },
        hideToken: { model.hideToken(botID) },
        copyToken: copyToken,
        requestRotation: { isConfirmingRotation = true }
      )

      IOSBotAgentsSection(botUserId: botID)

      Section {
        Button("Delete Bot…", role: .destructive) {
          isConfirmingDelete = true
        }
        .disabled(isBusy)
      }
    }
    .listStyle(.insetGrouped)
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(User(from: bot).displayName)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          saveProfile(bot)
        }
        .disabled(!canSave(bot))
      }
    }
    .sheet(isPresented: $showsImagePicker) {
      ImagePicker(sourceType: .photoLibrary) { image in
        pickedImage = image
        showsCropper = true
      }
    }
    .sheet(isPresented: $showsCropper, onDismiss: { pickedImage = nil }) {
      if let pickedImage {
        CircularCropView(image: pickedImage) { croppedImage in
          Task { await model.uploadPhoto(botID, image: croppedImage, realtimeV2: realtimeV2) }
        }
      }
    }
    .confirmationDialog(
      "Rotate Token?",
      isPresented: $isConfirmingRotation,
      titleVisibility: .visible
    ) {
      Button("Rotate Token", role: .destructive) {
        Task { await model.rotateToken(botID, realtimeV2: realtimeV2) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The current token will stop working immediately. Existing integrations must be updated with the new token.")
    }
    .confirmationDialog(
      "Delete Bot?",
      isPresented: $isConfirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete Bot", role: .destructive) {
        Task {
          if await model.delete(botID, realtimeV2: realtimeV2) {
            dismiss()
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This revokes the bot token. Existing messages remain in history.")
    }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var cleanUsername: String {
    IOSBotsSettingsModel.sanitizedUsername(username)
  }

  private func canSave(_ bot: InlineProtocol.User) -> Bool {
    guard !isBusy, !trimmedName.isEmpty, IOSBotsSettingsModel.isValidBotUsername(cleanUsername) else {
      return false
    }
    return trimmedName != User(from: bot).displayName || cleanUsername != bot.username
  }

  private func saveProfile(_ bot: InlineProtocol.User) {
    let nameToSend = trimmedName == User(from: bot).displayName ? nil : trimmedName
    let usernameToSend = cleanUsername == bot.username ? nil : cleanUsername

    Task {
      guard await model.updateProfile(
        botID,
        name: nameToSend,
        username: usernameToSend,
        realtimeV2: realtimeV2
      ), let updated = model.bot(botID) else { return }
      name = User(from: updated).displayName
      username = updated.username
      ToastManager.shared.showToast(
        "Bot profile updated",
        type: .success,
        systemImage: "checkmark.circle.fill"
      )
    }
  }

  private func openChat() {
    Task {
      guard await model.prepareChat(botID, realtimeV2: realtimeV2) else { return }
      router.dismissSheet()
      router.openPrimaryDestination(.chat(peer: .user(id: botID)))
    }
  }
}

private struct IOSManagedBotPhotoEditor: View {
  let bot: InlineProtocol.User
  let isBusy: Bool
  let choosePhoto: () -> Void
  let removePhoto: () -> Void

  var body: some View {
    Menu {
      Button(action: choosePhoto) {
        Label("Choose Photo", systemImage: "photo.on.rectangle")
      }
      if bot.hasProfilePhoto {
        Button(role: .destructive, action: removePhoto) {
          Label("Remove Photo", systemImage: "trash")
        }
      }
    } label: {
      ZStack(alignment: .bottomTrailing) {
        UserAvatar(user: User(from: bot), size: 96)

        Group {
          if isBusy {
            ProgressView()
              .tint(.white)
          } else {
            Image(systemName: "camera.fill")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 30, height: 30)
        .background(Color.accentColor, in: Circle())
        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
      }
    }
    .disabled(isBusy)
    .accessibilityLabel("Change Bot Photo")
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .listRowBackground(Color.clear)
  }
}

private struct IOSManagedBotAvatarSection: View {
  let bot: InlineProtocol.User
  let isBusy: Bool
  let clear: () -> Void

  var body: some View {
    Section {
      LabeledContent(
        "Avatar",
        value: bot.botAvatar.displayName.isEmpty ? "Configured" : bot.botAvatar.displayName
      )
      if bot.botAvatar.hasDescription_p, !bot.botAvatar.description_p.isEmpty {
        Text(bot.botAvatar.description_p)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button("Clear Bot Avatar", role: .destructive, action: clear)
        .disabled(isBusy)
    } header: {
      Text("Bot Avatar")
    } footer: {
      Text("Animated avatars are set by the bot’s integration.")
    }
  }
}

private struct IOSBotAgentsSection: View {
  @State private var model: BotAgentsSettingsModel
  @State private var editorItem: IOSBotAgentEditorItem?
  @State private var agentToDelete: InlineProtocol.BotAgent?

  init(botUserId: Int64) {
    _model = State(initialValue: BotAgentsSettingsModel(botUserId: botUserId))
  }

  var body: some View {
    Section {
      if model.isLoading, model.agents.isEmpty {
        HStack {
          ProgressView()
          Text("Loading Skilled Agents…")
            .foregroundStyle(.secondary)
        }
      } else if model.agents.isEmpty {
        Text("Create a Skilled Agent people can @mention in chats where this bot has access.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.agents, id: \.id) { agent in
          Button {
            editorItem = IOSBotAgentEditorItem(agent: agent)
          } label: {
            HStack(spacing: 10) {
              Text(agent.hasEmoji ? agent.emoji : "🤖")
                .font(.title2)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: Circle())
              VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                  .foregroundStyle(.primary)
                if agent.hasDescription_p, !agent.description_p.isEmpty {
                  Text(agent.description_p)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
          }
          .buttonStyle(.plain)
          .swipeActions {
            Button("Delete", role: .destructive) {
              agentToDelete = agent
            }
          }
        }
      }

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }

      if let skillErrorMessage = model.skillErrorMessage {
        Label(skillErrorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }

      Button {
        editorItem = IOSBotAgentEditorItem(agent: nil)
      } label: {
        Label("New Skilled Agent", systemImage: "plus")
      }
    } header: {
      Text("Skilled Agents")
    } footer: {
      Text("Skilled Agents reuse this bot’s harness, credentials, memory, skills, and chat access. Instructions and skill keys are visible only to bot managers and the harness.")
    }
    .task { await model.load() }
    .sheet(item: $editorItem) { item in
      IOSBotAgentEditor(
        agent: item.agent,
        isSaving: model.savingAgentId != nil,
        skills: model.skills,
        isLoadingSkills: model.isLoadingSkills,
        skillErrorMessage: model.skillErrorMessage,
        onLoadSkills: { await model.loadSkills() },
        onSave: { draft in
          await model.save(draft, agentId: item.agent?.id)
        },
        onDelete: item.agent.map { agent in
          { await model.delete(agentId: agent.id) }
        }
      )
    }
    .confirmationDialog(
      "Delete Skilled Agent?",
      isPresented: Binding(
        get: { agentToDelete != nil },
        set: { if !$0 { agentToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Skilled Agent", role: .destructive) {
        guard let agent = agentToDelete else { return }
        agentToDelete = nil
        editorItem = nil
        Task { await model.delete(agentId: agent.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Existing messages keep their text, but future mentions will no longer activate this specialization.")
    }
  }
}

private struct IOSBotAgentEditorItem: Identifiable {
  let agent: InlineProtocol.BotAgent?
  let id = UUID()
}

private struct IOSBotAgentEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: ManagedBotAgentDraft
  @State private var isSaving = false
  @State private var isDeleting = false
  @State private var isConfirmingDelete = false

  let agent: InlineProtocol.BotAgent?
  let externallySaving: Bool
  let skills: [InlineProtocol.BotSkill]
  let isLoadingSkills: Bool
  let skillErrorMessage: String?
  let onLoadSkills: () async -> Void
  let onSave: (ManagedBotAgentDraft) async -> Bool
  let onDelete: (() async -> Bool)?

  init(
    agent: InlineProtocol.BotAgent?,
    isSaving: Bool,
    skills: [InlineProtocol.BotSkill],
    isLoadingSkills: Bool,
    skillErrorMessage: String?,
    onLoadSkills: @escaping () async -> Void,
    onSave: @escaping (ManagedBotAgentDraft) async -> Bool,
    onDelete: (() async -> Bool)?
  ) {
    self.agent = agent
    externallySaving = isSaving
    self.skills = skills
    self.isLoadingSkills = isLoadingSkills
    self.skillErrorMessage = skillErrorMessage
    self.onLoadSkills = onLoadSkills
    self.onSave = onSave
    self.onDelete = onDelete
    _draft = State(initialValue: agent.map { ManagedBotAgentDraft(agent: $0) } ?? ManagedBotAgentDraft())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Identity") {
          TextField("Name", text: $draft.name)
          TextField("Handle (optional)", text: $draft.handle)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("Emoji (optional)", text: $draft.emoji)
          TextField("Description (optional)", text: $draft.description, axis: .vertical)
            .lineLimit(2 ... 4)
        }

        Section {
          Picker("Skill", selection: $draft.skillKey) {
            Text("None").tag("")
            if !draft.skillKey.isEmpty, !skills.contains(where: { $0.key == draft.skillKey }) {
              Text("Unavailable: \(draft.skillKey)").tag(draft.skillKey)
            }
            ForEach(skills, id: \.key) { skill in
              Text(skill.name).tag(skill.key)
            }
          }
          if isLoadingSkills {
            HStack(spacing: 8) {
              ProgressView()
              Text("Loading skills…")
                .foregroundStyle(.secondary)
            }
          }
          if let skillErrorMessage {
            Label(skillErrorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
          TextField("Instructions (optional)", text: $draft.instructions, axis: .vertical)
            .lineLimit(5 ... 12)
        } header: {
          Text("Harness")
        } footer: {
          Text("A name-only Skilled Agent is valid. Harnesses receive a minimal identity instruction when these fields are empty.")
        }

        if onDelete != nil {
          Section {
            Button("Delete Skilled Agent…", role: .destructive) {
              isConfirmingDelete = true
            }
            .disabled(isDeleting)
          }
        }
      }
      .navigationTitle(agent == nil ? "New Skilled Agent" : "Edit Skilled Agent")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            isSaving = true
            Task {
              if await onSave(draft) {
                dismiss()
              }
              isSaving = false
            }
          }
          .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || externallySaving)
        }
      }
      .confirmationDialog(
        "Delete Skilled Agent?",
        isPresented: $isConfirmingDelete,
        titleVisibility: .visible
      ) {
        Button("Delete Skilled Agent", role: .destructive) {
          isDeleting = true
          Task {
            if await onDelete?() == true {
              dismiss()
            }
            isDeleting = false
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Existing messages keep their text, but future mentions will no longer activate this specialization.")
      }
    }
    .task { await onLoadSkills() }
  }
}

private struct IOSManagedBotAccessSection: View {
  let token: String?
  let isBusy: Bool
  let revealToken: () -> Void
  let hideToken: () -> Void
  let copyToken: (String) -> Void
  let requestRotation: () -> Void

  var body: some View {
    Section {
      if let token {
        Text(token)
          .font(.caption.monospaced())
          .lineLimit(2)
          .truncationMode(.middle)
          .privacySensitive()

        Button("Copy Token") { copyToken(token) }
        Button("Hide Token", action: hideToken)
      } else {
        Button("Reveal Token", action: revealToken)
          .disabled(isBusy)
      }

      Button("Rotate Token…", role: .destructive, action: requestRotation)
        .disabled(isBusy)
    } header: {
      Text("Access Token")
    } footer: {
      Text("Keep this token private. Rotating it immediately revokes the previous token.")
    }
  }
}
