import Combine
import Foundation

/// One snapshot and its diff from the one before.
public struct ChatRowUpdate: Sendable {
  public let snapshot: ChatRowSnapshot
  public let diff: ChatRowDiff
}

/// Publishes a chat view model's row snapshots. Owned by
/// `MessagesProgressiveViewModel` (`rowFeed`), which publishes from every path
/// that changes its window. Runs alongside the existing change sets; nothing
/// here reads the database.
///
/// Off until a consumer sets `isPublishing`: until then a publication only
/// records the window and its reason (O(1)), and `snapshot` builds on first
/// read, so view models whose lists do not use rows pay nothing per update.
/// Publications made while off collapse into the one built on read.
@MainActor
public final class ChatRowFeed {
  /// What the view model holds, read when it publishes.
  public struct Source: Sendable {
    public var messages: [FullMessage]
    public var threadParent: FullMessage?
    public var coverage: ChatRowCoverage

    public init(messages: [FullMessage], threadParent: FullMessage?, coverage: ChatRowCoverage) {
      self.messages = messages
      self.threadParent = threadParent
      self.coverage = coverage
    }
  }

  /// The newest snapshot; the first frame reads it synchronously.
  public var snapshot: ChatRowSnapshot? {
    if pendingReason != nil { build() }
    return built
  }

  /// Build and send every publication. Turning it on brings `snapshot` up to date.
  public var isPublishing = false {
    didSet { if isPublishing, pendingReason != nil { build() } }
  }

  private var built: ChatRowSnapshot?
  private var pendingReason: ChatRowReason?
  /// Messages changed by the publications not yet built; nil when unknown.
  private var pendingChangedMessageIDs: Set<Int64>? = []
  public private(set) var chatKind: ChatRowChatKind = .group
  public private(set) var unreadLine: ChatRowBuilder.UnreadLine?
  public private(set) var collapsedMaxId: Int64?
  public private(set) var statusNotice: String?
  public var calendar: Calendar = .autoupdatingCurrent

  private var source: Source?
  private let subject = PassthroughSubject<ChatRowUpdate, Never>()

  public init() {}

  /// Each published snapshot with its diff, delivered synchronously on the main actor.
  public var updates: AnyPublisher<ChatRowUpdate, Never> { subject.eraseToAnyPublisher() }

  func configure(chatKind: ChatRowChatKind, unreadBoundary: Int64?, collapsedMaxId: Int64?) {
    self.chatKind = chatKind
    unreadLine = unreadBoundary.map { .init(boundary: $0) }
    self.collapsedMaxId = collapsedMaxId
  }

  /// Hides cleared history behind the collapsed-history marker.
  public func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    guard self.collapsedMaxId != collapsedMaxId else { return }
    self.collapsedMaxId = collapsedMaxId
    republishPresentation()
  }

  /// The line under the newest message. Shown only while the window reaches
  /// the newest cached message.
  public func setStatusNotice(_ text: String?) {
    guard statusNotice != text else { return }
    statusNotice = text
    republishPresentation()
  }

  /// Shows the unread line after this last read id; nil removes it.
  public func setUnreadBoundary(_ boundary: Int64?) {
    guard unreadLine?.boundary != boundary else { return }
    unreadLine = boundary.map { .init(boundary: $0) }
    republishPresentation()
  }

  private func republishPresentation() {
    guard let source else { return }
    publish(source, reason: .presentation)
  }

  /// The coverage of the window last published, built or not.
  var publishedCoverage: ChatRowCoverage? { source?.coverage }

  func publish(_ source: Source, reason: ChatRowReason, changedMessageIDs: Set<Int64>? = nil) {
    self.source = source
    if let changedMessageIDs, let pending = pendingChangedMessageIDs {
      pendingChangedMessageIDs = pending.union(changedMessageIDs)
    } else {
      pendingChangedMessageIDs = nil
    }
    if case let .jump(.unreadLine(boundary)) = reason, unreadLine == nil {
      unreadLine = .init(boundary: boundary)
    }
    // Unbuilt, the first snapshot stays the initial open.
    if built != nil || pendingReason == nil { pendingReason = reason }
    if isPublishing { build() }
  }

  private func build() {
    guard let source, let reason = pendingReason else { return }
    pendingReason = nil
    let changedMessageIDs = pendingChangedMessageIDs
    pendingChangedMessageIDs = []
    let output = ChatRowBuilder.build(.init(
      messages: source.messages,
      threadParent: source.threadParent,
      unreadLine: unreadLine,
      collapsedMaxId: collapsedMaxId,
      statusNotice: source.coverage.canLoadNewerFromLocal ? nil : statusNotice,
      chatKind: chatKind,
      reachesOldest: source.coverage.reachesOldest,
      calendar: calendar
    ))
    if let placed = output.unreadLineMessageId, unreadLine != nil {
      unreadLine?.pinnedMessageId = placed
    }
    let next = ChatRowSnapshot.next(
      after: built, rows: output.rows, reason: reason, coverage: source.coverage,
      unreadLineMessageId: output.unreadLineMessageId, changedMessageIDs: changedMessageIDs
    )
    let diff = ChatRowDiff(from: built, to: next)
    built = next
    subject.send(ChatRowUpdate(snapshot: next, diff: diff))
  }

  /// The messages a live publication changed, when it names them: an add, an
  /// edit or send result, a delete. Nil (compare every row) otherwise.
  nonisolated static func changedMessageIDs(
    for update: MessagesPublisher.UpdateType, previous: [FullMessage], current: [FullMessage]
  ) -> Set<Int64>? {
    switch update {
      case .add:
        let previousIDs = Set(previous.map(\.id))
        return Set(current.lazy.map(\.id).filter { !previousIDs.contains($0) })
      case let .update(change):
        return [change.message.id]
      case .delete:
        return []
      case .pinnedMessages, .acknowledgements, .reload:
        return nil
    }
  }

  /// The reason for a live publication, from the rows before and after it.
  nonisolated static func reason(
    for update: MessagesPublisher.UpdateType, previous: [FullMessage], current: [FullMessage]
  ) -> ChatRowReason {
    switch update {
      case .add:
        let previousIDs = Set(previous.map(\.id))
        let added = current.filter { !previousIDs.contains($0.id) }
        let isLocalSend = !added.isEmpty
          && added.allSatisfy { $0.message.messageId <= 0 && $0.message.out == true }
        return isLocalSend ? .localSend : .liveAdd
      case .update:
        let previousMessageIDs = Dictionary(previous.map { ($0.id, $0.message.messageId) }, uniquingKeysWith: { $1 })
        let acknowledged = current.contains { message in
          message.message.messageId > 0 && (previousMessageIDs[message.id].map { $0 <= 0 } ?? false)
        }
        return acknowledged ? .sendAck : .liveUpdate
      case .delete:
        return .delete
      case .pinnedMessages, .acknowledgements:
        return .liveUpdate
      case .reload:
        return .refresh
    }
  }
}

// MARK: - Publication from the view model

extension MessagesProgressiveViewModel {
  var rowFeedSource: ChatRowFeed.Source {
    .init(
      messages: messages,
      threadParent: threadAnchor,
      coverage: .init(
        reachesOldest: !canLoadOlderFromLocal && historyCoverage.hasCertifiedOlderEdge,
        reachesNewest: historyCoverage.isAtCertifiedLiveEnd,
        canLoadOlderFromLocal: canLoadOlderFromLocal,
        canLoadNewerFromLocal: canLoadNewerFromLocal
      )
    )
  }

  /// The first snapshot, once the opening window is installed.
  func publishInitialRows(openAnchor: ChatOpenAnchor, unreadBoundary: Int64?, collapsedMaxId: Int64?) {
    rowFeed.configure(
      chatKind: ChatRowChatKind(peer: peer), unreadBoundary: unreadBoundary, collapsedMaxId: collapsedMaxId
    )
    rowFeed.publish(rowFeedSource, reason: .initialOpen(openAnchor))
  }

  func publishRows(_ reason: ChatRowReason) {
    guard !isTrimmingWindow else { return }
    rowFeed.publish(rowFeedSource, reason: reason)
  }

  /// After a publisher update was applied. Publishes when rows changed, or when
  /// only the window's coverage did.
  func publishRows(after update: MessagesPublisher.UpdateType, previous: [FullMessage], changed: Bool) {
    // A trim's coverage is being read again: its publication carries this change too.
    guard !isTrimmingWindow else { return }
    let source = rowFeedSource
    guard changed || source.coverage != rowFeed.publishedCoverage else { return }
    rowFeed.publish(
      source, reason: ChatRowFeed.reason(for: update, previous: previous, current: source.messages),
      changedMessageIDs: ChatRowFeed.changedMessageIDs(for: update, previous: previous, current: source.messages)
    )
  }
}
