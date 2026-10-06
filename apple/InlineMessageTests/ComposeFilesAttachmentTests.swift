@testable import Auth
@testable import InlineIOS
@testable import InlineKit
@testable import TextProcessing
import Testing
import UIKit

@Suite("Files stays in the composer until Send", .serialized)
@MainActor
struct ComposeFilesAttachmentTests {
  @Test("Preparation preserves instructions, formatting and reply context", arguments: [false, true])
  func preparationPreservesComposeContext(video: Bool) async throws {
    let restore = preserveFixtureState()
    defer { restore() }
    let compose = makeCompose()
    let gate = DocumentPreparationGate()
    let originalText = NSAttributedString(attributedString: compose.textView.attributedText)
    let task = stageAttachment(compose, gate: gate, video: video) { true }

    #expect(compose.pendingVideoAttachments.count == 1)
    #expect(compose.attachmentItems.isEmpty)
    #expect(compose.textView.attributedText.isEqual(to: originalText))
    await gate.waitUntilStarted()
    gate.succeed(document)
    await task.value

    #expect(compose.pendingVideoAttachments.isEmpty)
    #expect(compose.attachmentItems[attachmentID(video: video)] != nil)
    #expect(compose.textView.attributedText.isEqual(to: originalText))
    #expect(ChatState.shared.getState(peer: peer).replyingMessageId == 137)
    #expect(!compose.sendButton.isHidden)
    #expect(compose.sendButton.isEnabled)
    compose.removeFile(attachmentID(video: video))
    #expect(compose.attachmentItems.isEmpty)
    #expect(compose.textView.attributedText.isEqual(to: originalText))
  }

  @Test("One explicit Send carries the file, instructions, entities and reply", .timeLimit(.minutes(1)), arguments: [false, true], [false, true])
  func explicitSendPayload(whilePreparing: Bool, video: Bool) async throws {
    let restore = preserveFixtureState()
    defer { restore() }
    let submissions = AttachmentSubmissionRecorder()
    let compose = makeCompose(submitAttachmentSend: submissions.record)
    let gate = DocumentPreparationGate()
    let task = stageAttachment(compose, gate: gate, video: video) { true }
    await gate.waitUntilStarted()
    #expect(submissions.transactions.isEmpty)
    if whilePreparing {
      compose.sendMessage(sendMode: .modeSilent)
      #expect(compose.sendButton.configuration?.showsActivityIndicator == true)
      #expect(submissions.transactions.isEmpty)
    }

    gate.succeed(document)
    await task.value
    if !whilePreparing {
      #expect(submissions.transactions.isEmpty)
      compose.sendMessage(sendMode: .modeSilent)
    }
    await submissions.waitUntilSubmitted()

    #expect(submissions.transactions.count == 1)
    let transaction = try #require(submissions.transactions.first)
    #expect(transaction.text == "Review this file")
    #expect(transaction.peerId == peer)
    #expect(transaction.chatId == 9_100_137)
    #expect(transaction.replyToMsgId == 137)
    #expect(transaction.sendMode == .modeSilent)
    #expect(transaction.entities?.entities.contains { $0.type == .bold && $0.offset == 0 && $0.length == 16 } == true)
    #expect(transaction.attachments.count == 1)
    #expect(video ? transaction.attachments.first?.media.asVideoLocalId() == 9_100_137 :
      transaction.attachments.first?.media.asDocumentLocalId() == 9_100_137)
    #expect(compose.textView.text.isEmpty)
    #expect(compose.attachmentItems.isEmpty)
    #expect(compose.pendingVideoAttachments.isEmpty)
    #expect(ChatState.shared.getState(peer: peer).replyingMessageId == nil)
  }

  @Test("Early Send waits; removal or clearing prevents late admission", arguments: [false, true], [false, true])
  func earlySendAndCancellation(clearAll: Bool, video: Bool) async throws {
    let restore = preserveFixtureState()
    defer { restore() }
    let compose = makeCompose()
    let gate = DocumentPreparationGate()
    let task = stageAttachment(compose, gate: gate, video: video) { true }
    await gate.waitUntilStarted()

    compose.sendMessage()
    #expect(compose.sendButton.configuration?.showsActivityIndicator == true)
    #expect(compose.textView.text == "Review this file")
    #expect(ChatState.shared.getState(peer: peer).replyingMessageId == 137)
    if clearAll {
      compose.clearAttachments()
    } else {
      compose.removePendingVideoAttachment(try #require(compose.pendingVideoAttachments.first?.id), userInitiated: true)
    }
    gate.succeed(document)
    await task.value

    #expect(compose.pendingVideoAttachments.isEmpty)
    #expect(compose.attachmentItems.isEmpty)
    #expect(compose.sendButton.configuration?.showsActivityIndicator == false)
    #expect(compose.textView.text == "Review this file")
    #expect(ChatState.shared.getState(peer: peer).replyingMessageId == 137)
  }

  @Test("Changed destination or failed preparation cancels an early Send", arguments: [false, true], [false, true])
  func staleOrFailedPreparation(fails: Bool, video: Bool) async {
    let restore = preserveFixtureState()
    defer { restore() }
    let compose = makeCompose()
    let gate = DocumentPreparationGate()
    var isCurrentDestination = true
    let task = stageAttachment(compose, gate: gate, video: video) { isCurrentDestination }
    await gate.waitUntilStarted()
    compose.sendMessage()
    #expect(compose.sendButton.configuration?.showsActivityIndicator == true)

    if fails {
      gate.fail()
    } else {
      isCurrentDestination = false
      gate.succeed(document)
    }
    await task.value

    #expect(compose.pendingVideoAttachments.isEmpty)
    #expect(compose.attachmentItems.isEmpty)
    #expect(compose.sendButton.configuration?.showsActivityIndicator == false)
    #expect(compose.textView.text == "Review this file")
    #expect(ChatState.shared.getState(peer: peer).replyingMessageId == 137)
  }

  @Test("A removed attachment's late failure leaves a newer explicit Send waiting", arguments: [false, true])
  func canceledOldFailurePreservesNewPendingSend(video: Bool) async throws {
    let restore = preserveFixtureState()
    defer { restore() }
    let compose = makeCompose()
    let oldGate = DocumentPreparationGate()
    let oldTask = stageAttachment(compose, gate: oldGate, video: video) { true }
    await oldGate.waitUntilStarted()
    compose.removePendingVideoAttachment(try #require(compose.pendingVideoAttachments.first?.id), userInitiated: true)

    let newGate = DocumentPreparationGate()
    let newTask = stageAttachment(compose, gate: newGate, video: video) { true }
    await newGate.waitUntilStarted()
    let newPendingId = try #require(compose.pendingVideoAttachments.first?.id)
    compose.sendMessage()
    oldGate.fail()
    await oldTask.value

    #expect(compose.pendingVideoAttachments.first?.id == newPendingId)
    #expect(compose.sendButton.configuration?.showsActivityIndicator == true)
    #expect(compose.textView.text == "Review this file")
    compose.removePendingVideoAttachment(newPendingId, userInitiated: true)
    newGate.succeed(document)
    await newTask.value
    #expect(compose.attachmentItems.isEmpty)
  }

  @Test("Files cannot be silently discarded by saving an edit", arguments: ["before", "preparing", "ready"], [false, true])
  func editingRefusesFiles(stage: String, video: Bool) async throws {
    let restore = preserveFixtureState()
    defer { restore() }
    let submissions = AttachmentSubmissionRecorder()
    let compose = makeCompose(submitAttachmentSend: submissions.record)
    let gate = DocumentPreparationGate()
    if stage == "before" {
      ChatState.shared.states[peer] = .init(editingMessageId: 138)
      let task = stageAttachment(compose, gate: gate, video: video) { true }
      await task.value
      #expect(compose.pendingVideoAttachments.isEmpty)
      #expect(compose.attachmentItems.isEmpty)
      #expect(!gate.hasStarted)
      #expect(submissions.transactions.isEmpty)
      return
    }

    let task = stageAttachment(compose, gate: gate, video: video) { true }
    await gate.waitUntilStarted()
    if stage == "preparing" {
      compose.sendMessage()
      #expect(compose.sendButton.configuration?.showsActivityIndicator == true)
      ChatState.shared.states[peer] = .init(editingMessageId: 138)
      gate.succeed(document)
      await task.value
      #expect(compose.pendingVideoAttachments.isEmpty)
      #expect(compose.attachmentItems.isEmpty)
      #expect(compose.sendButton.configuration?.showsActivityIndicator == false)
    } else {
      gate.succeed(document)
      await task.value
      ChatState.shared.states[peer] = .init(editingMessageId: 138)
      compose.sendMessage()
      #expect(compose.attachmentItems[attachmentID(video: video)] != nil)
    }
    #expect(submissions.transactions.isEmpty)
    #expect(compose.textView.text == "Review this file")
    #expect(ChatState.shared.getState(peer: peer).editingMessageId == 138)
  }

  @Test("Destination changes cancel old imports even after returning", arguments: [false, true], [false, true])
  func destinationChange(video: Bool, chatOnly: Bool) async throws {
    let restore = preserveFixtureState()
    defer { restore() }
    let compose = makeCompose()
    let oldGate = DocumentPreparationGate()
    let oldTask = stageAttachment(compose, gate: oldGate, video: video) { true }
    await oldGate.waitUntilStarted()
    compose.sendMessage()
    if chatOnly {
      compose.chatId = 9_100_138
      compose.chatId = 9_100_137
    } else {
      compose.peerId = .user(id: 9_100_138)
      compose.peerId = peer
    }
    #expect(compose.pendingVideoAttachments.isEmpty)
    #expect(compose.sendButton.configuration?.showsActivityIndicator == false)

    let newGate = DocumentPreparationGate()
    let newTask = stageAttachment(compose, gate: newGate, video: video) { true }
    await newGate.waitUntilStarted()
    compose.sendMessage()
    oldGate.succeed(document)
    await oldTask.value
    #expect(compose.attachmentItems.isEmpty)
    #expect(compose.pendingVideoAttachments.count == 1)
    #expect(compose.sendButton.configuration?.showsActivityIndicator == true)
    compose.clearAttachments()
    newGate.succeed(document)
    await newTask.value
  }

  @Test("Removing a ready attachment cancels Send waiting on another import", arguments: [false, true])
  func readyRemovalCancelsSend(video: Bool) async {
    let restore = preserveFixtureState()
    defer { restore() }
    let compose = makeCompose()
    compose.addAttachmentItem(.document(document))
    let gate = DocumentPreparationGate()
    let task = stageAttachment(compose, gate: gate, video: video) { true }
    await gate.waitUntilStarted()
    compose.sendMessage()
    compose.removeFile("document_9100137")
    #expect(compose.sendButton.configuration?.showsActivityIndicator == false)
    gate.succeed(document)
    await task.value
    #expect(compose.attachmentItems.count == 1)
    #expect(compose.textView.text == "Review this file")
    #expect(ChatState.shared.getState(peer: peer).replyingMessageId == 137)
    compose.clearAttachments()
  }

  @Test("The account token rejects an import after logout and same-account login", arguments: [false, true])
  func accountChange(video: Bool) async throws {
    let restore = preserveFixtureState()
    defer { restore() }
    let compose = makeCompose()
    let snapshot = AuthSnapshot(status: .authenticatedV3(userId: 9_100_137), didHydrate: true)
    let cache = AuthSnapshotCache(initial: snapshot)
    let token = try cache.makeAccountMutationToken()
    let gate = DocumentPreparationGate()
    let task = stageAttachment(compose, gate: gate, video: video) {
      (try? cache.validateAccountMutationToken(token)) != nil
    }
    await gate.waitUntilStarted()
    compose.sendMessage()
    cache.update(AuthSnapshot(status: .hydrating, didHydrate: false))
    cache.update(snapshot)
    gate.succeed(document)
    await task.value
    #expect(compose.attachmentItems.isEmpty)
    #expect(compose.pendingVideoAttachments.isEmpty)
    #expect(compose.sendButton.configuration?.showsActivityIndicator == false)
    #expect(compose.textView.text == "Review this file")
    #expect(ChatState.shared.getState(peer: peer).replyingMessageId == 137)
  }

  private func attachmentID(video: Bool) -> String {
    video ? "video_9100137" : "document_9100137"
  }

  private func stageAttachment(
    _ compose: ComposeView,
    gate: DocumentPreparationGate,
    video: Bool,
    isCurrentDestination: @escaping @MainActor () -> Bool
  ) -> Task<Void, Never> {
    if !video {
      return compose.stageDocumentAttachment(fileURL, loadDocument: gate.load, isCurrentDestination: isCurrentDestination)
    }
    return compose.stageVideoAttachment(fileURL, loadVideo: { url, _ in
      _ = try await gate.load(url)
      return VideoInfo(video: Video(
        id: 9_100_137, videoId: 9_100_137, date: .init(timeIntervalSince1970: 0),
        localPath: "inline-test-video.mov"
      ))
    }, isCurrentDestination: isCurrentDestination)
  }

  private var peer: Peer { .user(id: 9_100_137) }
  private var fileURL: URL { URL(fileURLWithPath: "/inline-test-document.txt") }
  private var document: DocumentInfo {
    DocumentInfo(document: Document(
      id: 9_100_137,
      documentId: 9_100_137,
      date: .init(timeIntervalSince1970: 0),
      fileName: "instructions.txt",
      mimeType: "text/plain",
      size: 12,
      cdnUrl: nil,
      localPath: "inline-test-document.txt",
      thumbnailPhotoId: nil
    ))
  }

  private func preserveFixtureState() -> () -> Void {
    let previous = ChatState.shared.states[peer]
    let savedDefaults = UserDefaults.standard.object(forKey: "chatStates")
    return {
      ChatState.shared.states[peer] = previous
      if let savedDefaults {
        UserDefaults.standard.set(savedDefaults, forKey: "chatStates")
      } else {
        UserDefaults.standard.removeObject(forKey: "chatStates")
      }
    }
  }

  private func makeCompose(
    submitAttachmentSend: @escaping (TransactionSendMessage) -> Void = { _ in
      Issue.record("Unexpected attachment send while staging or canceling")
    }
  ) -> ComposeView {
    let drafts = Drafts()
    let persistence = DraftPersistenceClient(
      registerIntent: { drafts.registerIntent(for: $0, kind: $1) },
      isLatestIntent: { drafts.isLatestIntent($0) },
      update: { _, _, _, _ in true },
      clear: { _, _ in true }
    )
    let compose = ComposeView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 100),
      draftManager: DraftManager(debounceDelay: 2, persistence: persistence),
      submitAttachmentSend: submitAttachmentSend
    )
    compose.peerId = peer
    compose.chatId = 9_100_137
    compose.textView.attributedText = NSAttributedString(
      string: "Review this file", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)]
    )
    ChatState.shared.states[peer] = .init(replyingMessageId: 137)
    compose.updateSendButtonVisibility()
    return compose
  }
}

@MainActor
private final class AttachmentSubmissionRecorder {
  private(set) var transactions: [TransactionSendMessage] = []
  private var submitted: CheckedContinuation<Void, Never>?

  func record(_ transaction: TransactionSendMessage) {
    transactions.append(transaction)
    submitted?.resume()
    submitted = nil
  }

  func waitUntilSubmitted() async {
    guard transactions.isEmpty else { return }
    await withCheckedContinuation { submitted = $0 }
  }
}

@MainActor
private final class DocumentPreparationGate {
  private var result: CheckedContinuation<DocumentInfo, Error>?
  private var started: CheckedContinuation<Void, Never>?
  private(set) var hasStarted = false

  func load(_ url: URL) async throws -> DocumentInfo {
    try await withCheckedThrowingContinuation { continuation in
      hasStarted = true
      result = continuation
      started?.resume()
      started = nil
    }
  }

  func waitUntilStarted() async {
    guard result == nil else { return }
    await withCheckedContinuation { started = $0 }
  }

  func succeed(_ document: DocumentInfo) {
    result?.resume(returning: document)
    result = nil
  }

  func fail() {
    result?.resume(throwing: CocoaError(.fileReadNoSuchFile))
    result = nil
  }
}
