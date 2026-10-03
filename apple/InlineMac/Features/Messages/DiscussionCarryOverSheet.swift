import AppKit
import Auth
import GRDB
import InlineKit
import InlineProtocol
import InlineUI
import Observation
import SwiftUI

private typealias Peer = InlineKit.Peer
private typealias Message = InlineKit.Message

/// Transient presentation for an ordinary chat draft. The durable submission
/// stays with Drafts2, while the destination chat owns its public history.
@MainActor
@Observable
private final class DiscussionCarryOverModel {
  let dependencies: AppDependencies
  let selectedMessages: [FullMessage]
  let availableMessages: [FullMessage]
  let sourcePeer: Peer
  let sourceChatId: Int64
  var messages: [FullMessage]
  var topic = ""
  var instruction = ""
  var destination: DiscussionCarryOverDraft.Destination = .independent
  var botUserId: Int64 = 0
  var bots: [InlineKit.User] = []
  var sourceBotIds = Set<Int64>()
  var includeRange = false
  var rangeStart: Int64
  var rangeEnd: Int64
  var isLoading = false
  var isSubmitting = false
  var hasPrepared = false
  var errorMessage: String?
  var savedIntent: DiscussionCarryOverDraft?
  var reviewingReplacement = false
  var reviewingCurrentSelection = false
  private var account: AuthAccountMutationToken?

  init(messages: [FullMessage], availableMessages: [FullMessage], dependencies: AppDependencies) {
    self.dependencies = dependencies
    let ordered = messages.sorted { $0.message.messageId < $1.message.messageId }
    self.messages = ordered
    selectedMessages = ordered
    self.availableMessages = availableMessages.filter {
      $0.chatId == ordered[0].chatId && $0.message.messageId > 0 && !$0.message.isServiceMessage
    }.sorted { $0.message.messageId < $1.message.messageId }
    sourcePeer = ordered[0].peerId
    sourceChatId = ordered[0].chatId
    rangeStart = ordered[0].message.messageId
    rangeEnd = ordered.last!.message.messageId
  }

  var canSubmit: Bool {
    guard !isLoading, !isSubmitting else { return false }
    // Opening an existing child validates that child directly. Agent catalog
    // preparation is required only when constructing a new submission.
    if existingDestination != nil { return account != nil }
    return hasPrepared && !messages.isEmpty
      && (botUserId == 0 || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      && (destination == .independent || botUserId == 0 || sourceBotIds.contains(botUserId))
  }

  var existingDestination: Peer? {
    guard savedIntent == nil, destination == .anchored else { return nil }
    return messages.first?.message.threadCardPeer
  }

  var availableBots: [InlineKit.User] {
    destination == .anchored ? bots.filter { sourceBotIds.contains($0.id) } : bots
  }

  func prepare() async {
    guard !hasPrepared, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let account = try Auth.shared.handle.beginAccountMutation()
      self.account = account
      let sourcePeer = sourcePeer
      let savedDraft = await Task.detached { Drafts2.shared.load(peer: sourcePeer)?.discussionCarryOver }.value
      if let draft = savedDraft {
        guard draft.authorUserId == account.userID else { throw DiscussionCarryOverError.accountChanged }
        restore(draft)
      } else {
        // Refresh exact IDs before previewing, so their revision contract and
        // visible media are the same snapshot that the user will submit.
        messages = includeRange ? try await loadRange(account: account) : try await refreshSelection(selectedMessages, account: account)
      }
      guard case let .listBots(catalog) = try await dependencies.realtimeV2.send(.listBots(), expectedAccount: account) else {
        throw DiscussionCarryOverError.agentLookupUnavailable
      }
      guard case let .getPeerBots(access)? = try await dependencies.realtimeV2.callRpcDirect(
        method: .getPeerBots, input: .getPeerBots(.with { $0.peerID = sourcePeer.toInputPeer() }), accountToken: account
      ) else {
        throw DiscussionCarryOverError.agentLookupUnavailable
      }
      var available: [InlineKit.User] = []
      for bot in catalog.bots where !available.contains(where: { $0.id == bot.id }) {
        available.append(InlineKit.User(from: bot))
      }
      var accessible = Set<Int64>()
      for peerBot in access.bots where peerBot.hasBot {
        accessible.insert(peerBot.bot.id)
        if !available.contains(where: { $0.id == peerBot.bot.id }) { available.append(InlineKit.User(from: peerBot.bot)) }
      }
      if let savedBot = savedIntent?.botUserId, !available.contains(where: { $0.id == savedBot }),
         let bot = try await dependencies.database.reader.read({ db in try InlineKit.User.fetchOne(db, id: savedBot) }) {
        available.append(bot)
      }
      try Auth.shared.handle.validateAccountMutation(account)
      bots = available.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      sourceBotIds = accessible
      hasPrepared = true
      errorMessage = nil
    } catch {
      hasPrepared = false
      errorMessage = "Could not load the discussion and available agents. Choose Reload Preview to retry. \(error.localizedDescription)"
    }
  }

  func updateContext() async {
    guard savedIntent == nil || reviewingReplacement, let account, !isSubmitting, !isLoading else { return }
    isLoading = true
    hasPrepared = false
    errorMessage = nil
    defer { isLoading = false }
    do {
      let selectionIds = reviewingReplacement && !reviewingCurrentSelection
        ? (savedIntent?.messages.map(\.message.messageId) ?? []) : selectedMessages.map(\.message.messageId)
      let refreshed = includeRange ? try await loadRange(account: account)
        : try await refreshMessages(ids: selectionIds, account: account, allowMissing: reviewingReplacement)
      try Task.checkCancellation()
      messages = refreshed
      try Auth.shared.handle.validateAccountMutation(account)
      hasPrepared = true
    } catch { errorMessage = error.localizedDescription }
  }

  private func refreshSelection(_ selection: [FullMessage], account: AuthAccountMutationToken) async throws -> [FullMessage] {
    try await refreshMessages(ids: selection.map(\.message.messageId), account: account)
  }

  private func refreshMessages(ids: [Int64], account: AuthAccountMutationToken, allowMissing: Bool = false) async throws -> [FullMessage] {
    var snapshots: [Int64: InlineProtocol.Message] = [:]
    for start in stride(from: 0, to: ids.count, by: 100) {
      let batch = Array(ids[start..<min(start + 100, ids.count)])
      let result = try await dependencies.realtimeV2.send(.getMessages(peer: sourcePeer, messageIds: batch), expectedAccount: account)
      guard case let .getMessages(response) = result else { throw DiscussionCarryOverError.invalidResponse }
      for message in response.messages {
        guard message.chatID == sourceChatId, message.peerID.toPeer() == sourcePeer,
              message.hasSourceSnapshot, !message.sourceSnapshot.isEmpty,
              snapshots[message.id] == nil else { throw DiscussionCarryOverError.reviewUnavailable }
        snapshots[message.id] = message
      }
    }
    guard Set(snapshots.keys).isSubset(of: Set(ids)), allowMissing || Set(snapshots.keys) == Set(ids) else {
      throw DiscussionCarryOverError.selectionChanged
    }
    return try await readMessages(ids: snapshots.keys.sorted()).map { $0.reviewedCarryOverSnapshot(from: snapshots[$0.message.messageId]!) }
  }

  private func loadRange(account: AuthAccountMutationToken) async throws -> [FullMessage] {
    let lower = min(rangeStart, rangeEnd)
    let upper = max(rangeStart, rangeEnd)
    var after = lower - 1
    var ids = Set<Int64>()
    while after < upper {
      let result = try await dependencies.realtimeV2.send(GetChatHistoryTransaction(
        peer: sourcePeer, mode: .historyModeNewer, afterID: after, limit: 100
      ), expectedAccount: account)
      guard case let .getChatHistory(response) = result else { throw DiscussionCarryOverError.invalidResponse }
      let page = response.messages.filter { $0.id > after && $0.id <= upper }
      ids.formUnion(page.map(\.id))
      guard let next = response.messages.map(\.id).max(), next > after else { break }
      after = next
    }
    guard ids.contains(lower), ids.contains(upper) else { throw DiscussionCarryOverError.selectionChanged }
    let context = try await refreshMessages(ids: ids.sorted(), account: account)
    guard !context.isEmpty else { throw DiscussionCarryOverError.selectionChanged }
    return context
  }

  private func readMessages(ids: [Int64]) async throws -> [FullMessage] {
    let chatId = sourceChatId
    let loaded = try await dependencies.database.reader.read { db in
      try FullMessage.queryRequest().filter(Message.Columns.chatId == chatId)
        .filter(ids.contains(Message.Columns.messageId)).fetchAll(db)
    }
    guard loaded.count == ids.count else { throw DiscussionCarryOverError.selectionChanged }
    return loaded.filter { !$0.message.isServiceMessage }.sorted { $0.message.messageId < $1.message.messageId }
  }

  private func restore(_ draft: DiscussionCarryOverDraft) {
    savedIntent = draft
    messages = draft.messages
    topic = draft.topic ?? ""
    instruction = draft.instruction
    if let entity = draft.instructionEntities?.entities.first,
       entity.offset == 0, entity.type == .mention, entity.length > 0,
       Int(entity.length) <= instruction.utf16.count {
      instruction = (instruction as NSString).substring(from: Int(entity.length)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    destination = draft.destination
    botUserId = draft.botUserId ?? 0
  }

  func reviewUpdatedContext(usingCurrentSelection: Bool = false) async {
    guard hasPrepared, let savedIntent, let account, !isSubmitting, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let selection = usingCurrentSelection ? selectedMessages : savedIntent.messages
      let updated = try await refreshMessages(ids: selection.map(\.message.messageId), account: account, allowMissing: true)
      try Auth.shared.handle.validateAccountMutation(account)
      messages = updated
      reviewingReplacement = true
      reviewingCurrentSelection = usingCurrentSelection
      destination = .independent
      includeRange = false
      hasPrepared = true
      errorMessage = updated.count < selection.count
        ? "Some source messages are no longer available. Review the remaining context or select a new range before creating a new chat." : nil
    } catch { errorMessage = error.localizedDescription }
  }

  func submit() async throws -> DiscussionCarryOverSubmission.Outcome {
    guard canSubmit, let account else { throw DiscussionCarryOverError.invalidResponse }
    isSubmitting = true
    errorMessage = nil
    defer { isSubmitting = false }
    try Auth.shared.handle.validateAccountMutation(account)
    if let peer = existingDestination { return try await openExisting(peer, account: account) }
    let intent: DiscussionCarryOverDraft
    if let savedIntent, !reviewingReplacement {
      intent = savedIntent
    } else {
      let result = try await dependencies.realtimeV2.send(.reserveChatIds(count: 1), expectedAccount: account)
      guard case let .reserveChatIds(response) = result, let reservation = response.reservations.first else {
        throw DiscussionCarryOverError.invalidResponse
      }
      let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
      let selectedBot = bots.first { $0.id == botUserId }
      if botUserId != 0 && selectedBot == nil { throw DiscussionCarryOverError.unavailableBot }
      let mention = selectedBot.map { "@\($0.shortDisplayName)" }
      let activation = mention.map { "\($0) \(text)" } ?? text
      let entities = mention.map { label in MessageEntities.with {
        $0.entities = [.with {
          $0.type = .mention; $0.offset = 0; $0.length = Int64(label.utf16.count); $0.mention.userID = botUserId
        }]
      } }
      intent = DiscussionCarryOverDraft(authorUserId: account.userID, messages: messages, destination: destination,
        reservedChatId: reservation.chatID, topic: topic, botUserId: selectedBot?.id,
        instruction: activation, instructionEntities: entities)
      try await Drafts2.shared.saveDiscussionCarryOver(peer: sourcePeer, draft: intent,
        replacing: reviewingReplacement ? savedIntent : nil)
      savedIntent = intent
      reviewingReplacement = false
    }
    let realtime = dependencies.realtimeV2
    let sourcePeer = sourcePeer
    let runner = DiscussionCarryOverSubmission(
      persist: { draft in
        try Auth.shared.handle.validateAccountMutation(account)
        try await Drafts2.shared.saveDiscussionCarryOver(peer: sourcePeer, draft: draft)
      },
      admit: { draft in
        try Auth.shared.handle.validateAccountMutation(account)
        try Drafts2.shared.requireCurrentDiscussionCarryOver(peer: sourcePeer, draft: draft)
      },
      create: { draft in
        switch draft.destination {
        case .independent:
          let result = try await realtime.send(.createChat(title: draft.topic, placeholderTitle: draft.topic == nil ? draft.placeholderTitle : nil,
            emoji: nil, isPublic: false, spaceId: nil, participants: [draft.authorUserId],
            reservedChatId: draft.reservedChatId), expectedAccount: account)
          guard case let .createChat(response) = result, response.hasChat else { throw DiscussionCarryOverError.invalidResponse }
          return response.chat.id
        case .anchored:
          let result = try await realtime.send(.createSubthread(parentChatId: draft.sourceChatId!,
            parentMessageId: draft.anchorMessageId, title: draft.topic ?? draft.placeholderTitle,
            reservedChatId: draft.reservedChatId), expectedAccount: account)
          guard case let .createSubthread(response) = result, response.hasChat else { throw DiscussionCarryOverError.invalidResponse }
          return response.chat.id
        }
      },
      forward: { draft in
        // Inspect the destination's current public history before a partial or
        // ambiguous retry. The immutable receipt keys reconcile exact batches.
        try Drafts2.shared.requireCurrentDiscussionCarryOver(peer: sourcePeer, draft: draft)
        _ = try await realtime.send(.getChatHistory(peer: .thread(id: draft.reservedChatId)), expectedAccount: account)
        var precedingMessageId: Int64 = 0
        for start in stride(from: 0, to: draft.messages.count, by: 100) {
          try Drafts2.shared.requireCurrentDiscussionCarryOver(peer: sourcePeer, draft: draft)
          let end = min(start + 100, draft.messages.count)
          let batch = Array(draft.messages[start..<end])
          let transaction = ForwardMessagesTransaction(fromPeerId: sourcePeer,
            toPeerId: .thread(id: draft.reservedChatId), messageIds: batch.map(\.message.messageId),
            shareForwardHeader: false,
            submissions: (start..<end).map {
              .init(expectedSourceRevision: draft.messages[$0].message.rev,
                    expectedSourceSnapshot: draft.messages[$0].message.sourceSnapshot,
                    randomId: draft.forwardingRandomIds[$0])
            })
          let result = try await realtime.send(transaction, expectedAccount: account)
          try Drafts2.shared.requireCurrentDiscussionCarryOver(peer: sourcePeer, draft: draft)
          guard case let .forwardMessages(response) = result else { throw DiscussionCarryOverError.invalidResponse }
          let receipts = try transaction.receipts(from: response)
          for receipt in receipts {
            guard receipt.messageId > precedingMessageId else { throw DiscussionCarryOverError.invalidResponse }
            precedingMessageId = receipt.messageId
          }
        }
      },
      addParticipant: { chatId, botId in
        _ = try await realtime.send(.addChatParticipant(chatID: chatId, userID: botId), expectedAccount: account)
      },
      activate: { draft in
        _ = try await realtime.send(.sendMessage(text: draft.instruction, peerId: .thread(id: draft.reservedChatId),
          chatId: draft.reservedChatId, entities: draft.instructionEntities,
          randomId: draft.activationRandomId, deferLocalMessage: true), expectedAccount: account)
      }
    )
    do {
      let outcome = try await runner.submit(intent)
      try Auth.shared.handle.validateAccountMutation(account)
      try await Drafts2.shared.saveDiscussionCarryOver(peer: sourcePeer, draft: nil, expectedReservationId: intent.reservedChatId)
      try Auth.shared.handle.validateAccountMutation(account)
      savedIntent = nil
      return outcome
    } catch {
      // The seed checkpoint can have advanced before a later RPC failed.
      if let current = Drafts2.shared.cached(peer: sourcePeer)?.discussionCarryOver { restore(current) }
      else if case .anotherSubmissionInProgress? = error as? DiscussionCarryOverPersistenceError {
        savedIntent = nil
        hasPrepared = false
      } else { savedIntent = intent }
      reviewingReplacement = false
      if case .anotherSubmissionInProgress? = error as? DiscussionCarryOverPersistenceError {
        errorMessage = "The saved chat changed in another window. Review its current preview before continuing."
      } else {
        errorMessage = "Could not confirm completion. The saved selection and destination will be used on retry. \(error.localizedDescription)"
      }
      throw error
    }
  }

  func openSavedChat() async throws -> DiscussionCarryOverSubmission.Outcome {
    guard let savedIntent, let account, !isSubmitting, !isLoading,
          savedIntent.authorUserId == account.userID else { throw DiscussionCarryOverError.accountChanged }
    isSubmitting = true
    errorMessage = nil
    defer { isSubmitting = false }
    return try await openExisting(.thread(id: savedIntent.reservedChatId), account: account)
  }

  private func openExisting(_ peer: Peer, account: AuthAccountMutationToken) async throws -> DiscussionCarryOverSubmission.Outcome {
    let realtime = dependencies.realtimeV2
    return try await DiscussionCarryOverSubmission.openExistingChat(peer: peer,
      fetch: { try await realtime.send(.getChat(peer: $0), expectedAccount: account) },
      validateAccount: { try Auth.shared.handle.validateAccountMutation(account) })
  }
}

struct DiscussionCarryOverSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: DiscussionCarryOverModel
  let onComplete: (DiscussionCarryOverSubmission.Outcome) -> Void

  init(messages: [FullMessage], availableMessages: [FullMessage], dependencies: AppDependencies,
       onComplete: @escaping (DiscussionCarryOverSubmission.Outcome) -> Void) {
    _model = State(initialValue: DiscussionCarryOverModel(messages: messages,
      availableMessages: availableMessages, dependencies: dependencies))
    self.onComplete = onComplete
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(model.existingDestination != nil ? "Open Reply Thread" : model.reviewingReplacement ? "Review Updated Context" : model.savedIntent == nil ? "Start Chat with Discussion" : "Finish Saved Chat")
          .font(.headline)
        Spacer()
        Button("Close") { dismiss() }.disabled(model.isSubmitting)
      }
      VStack(alignment: .leading, spacing: 10) {
        Picker("Destination", selection: $model.destination) {
          Text("Independent Chat").tag(DiscussionCarryOverDraft.Destination.independent)
          Text("Reply Thread").tag(DiscussionCarryOverDraft.Destination.anchored)
        }.pickerStyle(.segmented)
        if model.existingDestination != nil {
          Text("This reply thread already exists. Open it to continue, or choose Independent Chat to carry this discussion into a new chat.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          TextField("Topic (optional)", text: $model.topic)
          Picker("Agent", selection: $model.botUserId) {
            Text("No agent").tag(Int64(0))
            ForEach(model.availableBots) { bot in Text(bot.displayName).tag(bot.id) }
          }
          TextField("Current instruction or starter (optional)", text: $model.instruction, axis: .vertical)
            .lineLimit(2...4)
          if model.botUserId != 0 && model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Add a current instruction to start the agent after the context arrives.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if model.destination == .anchored {
            Text("A new reply thread receives the previewed context.")
              .font(.caption).foregroundStyle(.secondary)
            if model.botUserId != 0 && !model.sourceBotIds.contains(model.botUserId) {
              Text("Choose an agent that has access to this discussion, or create an independent chat.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          if model.availableMessages.count > 1 {
            Toggle("Carry the whole range", isOn: $model.includeRange)
            if model.includeRange {
              HStack {
                rangePicker("From", selection: $model.rangeStart)
                rangePicker("Through", selection: $model.rangeEnd)
              }
            }
          }
        }
      }
      .disabled((model.savedIntent != nil && !model.reviewingReplacement) || model.isSubmitting || model.isLoading)
      if model.reviewingReplacement {
        Text("Creating a new chat keeps the previous chat and its copied history. Review the updated context before continuing.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if model.savedIntent != nil {
        HStack {
          Button("Review Updated Context") { Task { await model.reviewUpdatedContext() } }
          Button("Use Current Selection") { Task { await model.reviewUpdatedContext(usingCurrentSelection: true) } }
        }.disabled(model.isSubmitting || model.isLoading || !model.hasPrepared)
      }
      Divider()
      HStack {
        Text("\(model.messages.count) messages in order").font(.subheadline.weight(.medium))
        Spacer()
        if model.isLoading { ProgressView().controlSize(.small) }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(model.messages) { fullMessage in
            DiscussionCarryOverPreview(message: fullMessage)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }.background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
      if let error = model.errorMessage {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        if !model.hasPrepared, !model.isLoading {
          Button("Reload Preview") { Task {
            if model.reviewingReplacement { await model.updateContext() }
            else { await model.prepare() }
          } }
        }
        if model.savedIntent != nil {
          Button("Open Saved Chat") {
            Task { @MainActor in
              do {
                let outcome = try await model.openSavedChat()
                onComplete(outcome)
                dismiss()
              } catch { model.errorMessage = "Could not open the saved chat. \(error.localizedDescription)" }
            }
          }.disabled(model.isSubmitting || model.isLoading)
        }
        Spacer()
        if model.isSubmitting { ProgressView().controlSize(.small) }
        Button(model.reviewingReplacement ? "Create New Chat" : model.existingDestination != nil ? "Open Reply Thread" : model.savedIntent == nil ? "Create Chat" : "Retry Saved Chat") {
          Task { @MainActor in
            do {
              let outcome = try await model.submit()
              onComplete(outcome)
              dismiss()
            } catch { if model.errorMessage == nil { model.errorMessage = error.localizedDescription } }
          }
        }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canSubmit)
      }
    }
    .padding(20).frame(width: 560, height: 700)
    .interactiveDismissDisabled(model.isSubmitting)
    .onExitCommand { if !model.isSubmitting { dismiss() } }
    .task { await model.prepare() }
    .task(id: "\(model.includeRange)-\(model.rangeStart)-\(model.rangeEnd)") {
      await model.updateContext()
    }
  }

  private func rangePicker(_ title: String, selection: Binding<Int64>) -> some View {
    Picker(title, selection: selection) {
      ForEach(model.availableMessages) { message in
        Text("\(message.message.messageId): \(message.message.text?.prefix(48) ?? "Media")")
          .tag(message.message.messageId)
      }
    }
  }
}

private struct DiscussionCarryOverPreview: View {
  let message: FullMessage
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message.senderInfo?.user.displayName ?? "Sender").font(.caption.weight(.medium))
      Text(message.discussionCarryOverText).font(.system(size: 13))
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if let photo = message.photoInfo { previewPhoto(photo) }
      ForEach(Array(message.discussionCarryOverBlockImages.enumerated()), id: \.offset) { _, photo in
        if let photo { previewPhoto(photo) }
        else { Label("Image unavailable in copied history", systemImage: "photo") }
      }
      if let video = message.videoInfo {
        if let thumbnail = video.thumbnail { previewPhoto(thumbnail) }
        Label("Video · \(video.video.duration ?? 0)s", systemImage: "play.rectangle")
      }
      if let document = message.documentInfo {
        if let thumbnail = document.thumbnail { previewPhoto(thumbnail) }
        Label(document.document.fileName ?? "Document", systemImage: "doc")
      }
      if let voice = message.message.voiceContent {
        Label("Voice message · \(voice.duration)s", systemImage: "waveform")
      }
      ForEach(message.attachments) { attachment in
        if let preview = attachment.urlPreview {
          if let photo = attachment.photoInfo { previewPhoto(photo) }
          if let title = preview.title { Text(title).font(.caption.weight(.medium)) }
          if let description = preview.description { Text(description).font(.caption) }
          Text(preview.url).font(.caption).foregroundStyle(.secondary)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func previewPhoto(_ photo: PhotoInfo) -> some View {
    DiscussionCarryOverPhoto(photo: photo).frame(width: 220, height: 130)
      .clipShape(RoundedRectangle(cornerRadius: 5))
  }
}

private struct DiscussionCarryOverPhoto: NSViewRepresentable {
  let photo: PhotoInfo
  func makeNSView(context: Context) -> PlatformPhotoView {
    let view = PlatformPhotoView()
    view.photoContentMode = .aspectFit
    return view
  }
  func updateNSView(_ view: PlatformPhotoView, context: Context) { view.setPhoto(photo) }
}

private enum DiscussionCarryOverError: LocalizedError {
  case accountChanged, invalidResponse, selectionChanged, unavailableBot, reviewUnavailable, agentLookupUnavailable
  var errorDescription: String? {
    switch self {
    case .accountChanged: "The account changed. Reopen the discussion from the current account."
    case .invalidResponse: "The server did not confirm this step. Retry the saved chat."
    case .selectionChanged: "Some selected messages are no longer available. Reload the selection before creating a chat."
    case .reviewUnavailable: "The server could not provide a complete discussion snapshot. Reload after the server supports this workflow."
    case .unavailableBot: "Choose an available agent before creating the chat."
    case .agentLookupUnavailable: "The server did not provide the agent catalog and discussion access."
    }
  }
}
