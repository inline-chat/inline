import AppKit
import Combine
import Foundation
import InlineKit
import InlineProtocol

/// The destination selected outside Compose. The shape intentionally makes a
/// public Home thread impossible to represent.
enum NewThreadComposeDestination: Equatable {
  case home
  case space(id: Int64, visibility: SpaceVisibility)

  enum SpaceVisibility: Equatable {
    case `private`
    case `public`
  }

  var spaceID: Int64? {
    if case let .space(id, _) = self { id } else { nil }
  }

  var isPublic: Bool {
    if case .space(_, .public) = self { true } else { false }
  }
}

/// A destination-aware source for the existing mention menu. Chat Compose
/// continues using ChatParticipantsWithMembersViewModel directly; only the
/// new-thread usage receives this service.
@MainActor
protocol NewThreadComposeMentionSource: AnyObject {
  var candidates: MentionCompletionCandidates { get }
  var candidateUpdates: AnyPublisher<MentionCompletionCandidates, Never> { get }

  func setDestination(_ destination: NewThreadComposeDestination)
  func refresh() async
}

/// Window-local attachment materialization for the short interval before a
/// real thread peer exists. It deliberately uses the same FileCache media
/// values as Drafts2, but does not invent a temporary peer or persist a draft
/// under somebody else's peer key.
@MainActor
final class NewThreadComposeAttachmentStore {
  private(set) var attachments: [Drafts2Attachment] = []
  private(set) var pendingIDs: Set<String> = []

  private var tasks: [String: Task<Void, Never>] = [:]

  var hasPendingAttachments: Bool {
    !pendingIDs.isEmpty
  }

  @discardableResult
  func addImage(
    _ image: NSImage,
    preferredFormat: ImageFormat?,
    fallbackURL: URL?,
    completion: @escaping Drafts2AttachmentCompletion
  ) -> String {
    materialize(prefix: "pending_photo", completion: completion) {
      try await AttachmentMediaMaterializer.image(
        image,
        preferredFormat: preferredFormat,
        sourceURL: fallbackURL
      )
    }
  }

  @discardableResult
  func addVideo(
    _ url: URL,
    thumbnail: NSImage?,
    completion: @escaping Drafts2AttachmentCompletion
  ) -> String {
    materialize(prefix: "pending_video", completion: completion) {
      try await AttachmentMediaMaterializer.video(url, thumbnail: thumbnail)
    }
  }

  @discardableResult
  func addAnimatedImage(
    _ url: URL,
    completion: @escaping Drafts2AttachmentCompletion
  ) -> String {
    materialize(prefix: "pending_animated_image", completion: completion) {
      try await AttachmentMediaMaterializer.animatedImage(url)
    }
  }

  @discardableResult
  func addFile(
    _ url: URL,
    completion: @escaping Drafts2AttachmentCompletion
  ) -> String {
    materialize(prefix: "pending_document", completion: completion) {
      try await AttachmentMediaMaterializer.file(url)
    }
  }

  func remove(id: String) {
    pendingIDs.remove(id)
    tasks.removeValue(forKey: id)?.cancel()
    attachments.removeAll { $0.id == id }
  }

  func contains(id: String) -> Bool {
    attachments.contains { $0.id == id }
  }

  func clear() {
    let activeTasks = Array(tasks.values)
    tasks.removeAll()
    pendingIDs.removeAll()
    attachments.removeAll()
    activeTasks.forEach { $0.cancel() }
  }

  private func materialize(
    prefix: String,
    completion: @escaping Drafts2AttachmentCompletion,
    makeMedia: @escaping @Sendable () async throws -> FileMediaItem
  ) -> String {
    let pendingID = "\(prefix)_\(UUID().uuidString)"
    pendingIDs.insert(pendingID)
    completion(.pending(pendingId: pendingID))

    let task = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        let media = try await makeMedia()
        try Task.checkCancellation()
        await self?.finish(pendingID: pendingID, media: media, completion: completion)
      } catch is CancellationError {
        await self?.cancel(pendingID: pendingID, completion: completion)
      } catch {
        await self?.fail(pendingID: pendingID, error: error, completion: completion)
      }
    }
    tasks[pendingID] = task
    return pendingID
  }

  private func finish(
    pendingID: String,
    media: FileMediaItem,
    completion: Drafts2AttachmentCompletion
  ) {
    guard pendingIDs.remove(pendingID) != nil else { return }
    tasks.removeValue(forKey: pendingID)
    let attachment = Drafts2Attachment(id: media.getItemUniqueId(), media: media)
    attachments.removeAll { $0.id == attachment.id }
    attachments.append(attachment)
    completion(.success(pendingId: pendingID, attachment: attachment))
  }

  private func cancel(
    pendingID: String,
    completion: Drafts2AttachmentCompletion
  ) {
    guard pendingIDs.remove(pendingID) != nil else { return }
    tasks.removeValue(forKey: pendingID)
    completion(.cancelled(pendingId: pendingID))
  }

  private func fail(
    pendingID: String,
    error: Error,
    completion: Drafts2AttachmentCompletion
  ) {
    guard pendingIDs.remove(pendingID) != nil else { return }
    tasks.removeValue(forKey: pendingID)
    completion(.failure(pendingId: pendingID, message: error.localizedDescription))
  }
}

@MainActor
final class DefaultNewThreadComposeMentionSource: NewThreadComposeMentionSource {
  private let viewModel: NewThreadMentionCandidatesViewModel
  private let updates: CurrentValueSubject<MentionCompletionCandidates, Never>
  private var agents: [MentionableBotAgent] = []
  private var cancellable: AnyCancellable?

  var candidates: MentionCompletionCandidates {
    merged(viewModel.candidates)
  }

  var candidateUpdates: AnyPublisher<MentionCompletionCandidates, Never> {
    viewModel.startObserving()
    updates.send(candidates)
    return updates.removeDuplicates().eraseToAnyPublisher()
  }

  init(db: AppDatabase, destination: NewThreadComposeDestination) {
    let viewModel = NewThreadMentionCandidatesViewModel(db: db, spaceID: destination.spaceID)
    self.viewModel = viewModel
    updates = CurrentValueSubject(viewModel.candidates)
    cancellable = viewModel.$candidates.sink { [weak self] candidates in
      guard let self else { return }
      updates.send(merged(candidates))
    }
  }

  func setDestination(_ destination: NewThreadComposeDestination) {
    viewModel.setSpaceID(destination.spaceID)
  }

  func refresh() async {
    await viewModel.refresh()
  }

  func setAgents(_ agents: [MentionableBotAgent]) {
    self.agents = agents
    updates.send(candidates)
  }

  private func merged(_ candidates: MentionCompletionCandidates) -> MentionCompletionCandidates {
    var candidates = candidates
    candidates.agents = agents
    return candidates
  }
}

/// The immutable authoring result captured synchronously from the real Glass
/// editor before any thread creation or network work starts.
struct PreparedNewThreadDraft {
  let authorUserID: Int64
  let text: String
  let entities: MessageEntities?
  let attachments: [Drafts2Attachment]
  let destination: NewThreadComposeDestination
  let sendSilently: Bool
  let mentionedUserIDs: Set<Int64>
  let mentionedGroupIDs: Set<Int64>
  let agentContext: InlineProtocol.AgentThreadContext?

  init(
    authorUserID: Int64,
    text: String,
    entities: MessageEntities?,
    attachments: [Drafts2Attachment],
    destination: NewThreadComposeDestination,
    sendSilently: Bool,
    agentContext: InlineProtocol.AgentThreadContext? = nil
  ) {
    self.authorUserID = authorUserID
    self.text = text
    self.entities = Drafts2.normalizedEntities(entities)
    self.attachments = attachments
    self.destination = destination
    self.sendSilently = sendSilently
    self.agentContext = agentContext
    mentionedUserIDs = Self.mentionedUserIDs(in: entities)
    mentionedGroupIDs = Self.mentionedGroupIDs(in: entities)
  }

  var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
  }

  private static func mentionedUserIDs(in entities: MessageEntities?) -> Set<Int64> {
    guard let entities else { return [] }
    return Set(entities.entities.compactMap { entity in
      guard entity.type == .mention, entity.mention.userID > 0 else { return nil }
      return entity.mention.userID
    })
  }

  private static func mentionedGroupIDs(in entities: MessageEntities?) -> Set<Int64> {
    guard let entities else { return [] }
    return Set(entities.entities.compactMap { entity in
      guard entity.type == .groupMention, entity.groupMention.groupID > 0 else { return nil }
      return entity.groupMention.groupID
    })
  }
}

struct NewThreadComposeSubmissionFailure: LocalizedError {
  let message: String
  let createdPeer: InlineKit.Peer?

  var errorDescription: String? {
    message
  }
}

enum NewThreadComposeSubmissionIntent {
  case openThread
  case stayInCurrentView
}

/// Everything the real Glass composer needs from a pre-chat host. The host
/// supplies one opaque accessory view; Compose owns its placement without
/// learning what the contextual controls mean.
@MainActor
struct NewThreadComposeContext {
  typealias Submit = @MainActor (PreparedNewThreadDraft, NewThreadComposeSubmissionIntent) async
    -> Result<InlineKit.Peer, NewThreadComposeSubmissionFailure>

  let sessionID: UUID
  let destination: @MainActor () -> NewThreadComposeDestination
  let sendSilently: @MainActor () -> Bool
  let setSendSilently: @MainActor (Bool) -> Void
  let agentContext: @MainActor () -> InlineProtocol.AgentThreadContext?
  let mentionSource: any NewThreadComposeMentionSource
  let attachmentStore: NewThreadComposeAttachmentStore
  let overlayHostView: @MainActor () -> NSView?
  let supplementaryAccessoryView: NSView
  let placeholderSymbolName: String?
  let didChangeDraft: @MainActor (_ text: String, _ entities: MessageEntities?, _ hasAttachments: Bool) -> Void
  let didChangeHeight: @MainActor (_ height: CGFloat) -> Void
  let didFinishSubmission: @MainActor (_ result: Result<InlineKit.Peer, NewThreadComposeSubmissionFailure>) -> Void
  let submit: Submit

  init(
    sessionID: UUID = UUID(),
    destination: @escaping @MainActor () -> NewThreadComposeDestination,
    sendSilently: @escaping @MainActor () -> Bool,
    setSendSilently: @escaping @MainActor (Bool) -> Void,
    agentContext: @escaping @MainActor () -> InlineProtocol.AgentThreadContext? = { nil },
    mentionSource: any NewThreadComposeMentionSource,
    attachmentStore: NewThreadComposeAttachmentStore,
    overlayHostView: @escaping @MainActor () -> NSView?,
    supplementaryAccessoryView: NSView,
    placeholderSymbolName: String? = nil,
    didChangeDraft: @escaping @MainActor (String, MessageEntities?, Bool) -> Void,
    didChangeHeight: @escaping @MainActor (CGFloat) -> Void,
    didFinishSubmission: @escaping @MainActor (Result<InlineKit.Peer, NewThreadComposeSubmissionFailure>) -> Void,
    submit: @escaping Submit
  ) {
    self.sessionID = sessionID
    self.destination = destination
    self.sendSilently = sendSilently
    self.setSendSilently = setSendSilently
    self.agentContext = agentContext
    self.mentionSource = mentionSource
    self.attachmentStore = attachmentStore
    self.overlayHostView = overlayHostView
    self.supplementaryAccessoryView = supplementaryAccessoryView
    self.placeholderSymbolName = placeholderSymbolName
    self.didChangeDraft = didChangeDraft
    self.didChangeHeight = didChangeHeight
    self.didFinishSubmission = didFinishSubmission
    self.submit = submit
  }
}

/// Top-level usage selection for Glass Compose. The existing chat initializer
/// and the All Chats host are the only construction paths.
@MainActor
enum ComposeUsage {
  case chat
  case newThread(NewThreadComposeContext)
}
