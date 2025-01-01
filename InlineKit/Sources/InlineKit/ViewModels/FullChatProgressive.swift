import Combine
import GRDB

/// todos
/// - listen to changes of count to first id - last id to detect new messages in between
/// - do a refetch on update instead of manually checking things (90/10)
/// -

@MainActor
public class MessagesProgressiveViewModel {
  // props
  public var peer: Peer

  // state
  public var messages: [FullMessage] = []

  public var minGlobalId: Int64 = 0
  public var maxGlobalId: Int64 = 0

  // internals
  private let initialLimit = 20
  private let log = Log.scoped("MessagesViewModel", enableTracing: true)
  private let db = AppDatabase.shared
  private var cancellable = Set<AnyCancellable>()
  private var callback: ((_ changeSet: MessagesChangeSet) -> Void)?

  // Note:
  // limit, cursor, range, etc are internals to this module. the view layer should not care about this.
  public init(peer: Peer) {
    self.peer = peer

    // get initial batch
    loadMessages(limit: initialLimit)

    // initial range
    updateRange()

    // subscribe to changes
    MessagesPublisher.shared.publisher
      .sink { [weak self] update in
        guard let self = self else { return }
        Log.shared.debug("Received update \(update)")
        if let changeset = applyChanges(update: update) {
          callback?(changeset)
        }
      }
      .store(in: &cancellable)
  }

  // Set an observer to update the UI
  public func observe(_ callback: @escaping (MessagesChangeSet) -> Void) {
    if self.callback != nil {
      Log.shared.warning("Callback already set, re-setting it to a new one will result in undefined behaviour")
    }

    self.callback = callback
  }

  public enum MessagesChangeSet {
    case added([FullMessage], indexSet: [Int])
    case updated([FullMessage], indexSet: [Int])
    case deleted([Int64], indexSet: [Int])
    case reload
  }

  private func applyChanges(update: MessagesPublisher.UpdateType) -> MessagesChangeSet? {
    switch update {
    case .add(let messageAdd):
      if messageAdd.peer == peer {
        // TODO: detect if we should add to the bottom or top
        messages.append(contentsOf: messageAdd.messages)
        // sort again
        sort()
        updateRange()

        // Return changeset
        return MessagesChangeSet.added(messageAdd.messages, indexSet: [messages.count - 1])
      }

    case .delete(let messageDelete):
      if messageDelete.peer == peer {
        let deletedIndices = messages.enumerated()
          .filter { messageDelete.messageIds.contains($0.element.id) }
          .map { $0.offset }

        // Store indices in reverse order to safely remove items
        let sortedIndices = deletedIndices.sorted(by: >)

        // Remove messages
        sortedIndices.forEach { messages.remove(at: $0) }

        // Update ange
        updateRange()

        // Return changeset
        return MessagesChangeSet.deleted(messageDelete.messageIds, indexSet: sortedIndices)
      }

    case .update(let messageUpdate):
      if messageUpdate.peer == peer {
        guard let index = messages.firstIndex(where: { $0.id == messageUpdate.message.id }) else {
          // not in our range
          return nil
        }

        messages[index] = messageUpdate.message
        updateRange() // ??
        return MessagesChangeSet.updated([messageUpdate.message], indexSet: [index])
      }

    case .reload(let peer):
      if peer == self.peer {
        // 90/10 solution TODO: quick way to optimize is to check if updated messages are in the current range
        refetchCurrentRange()

        return MessagesChangeSet.reload
      }
    }

    return nil
  }

  private func sort() {
    messages = messages.sorted(by: { $0.message.date < $1.message.date })
  }

  private func updateRange() {
    var lowestId = messages.first?.message.globalId ?? 0
    var highestId = messages.last?.message.globalId ?? 0

    for message in messages {
      guard let globalId = message.message.globalId else { continue }

      if globalId < lowestId {
        lowestId = globalId
      } else if globalId > highestId {
        highestId = globalId
      }
    }

    minGlobalId = lowestId
    maxGlobalId = highestId

    log.trace("Updated range: \(minGlobalId) - \(maxGlobalId)")
  }

  private func refetchCurrentRange() {
    loadMessages(preserveRange: true)
  }

  private func loadMessages(limit: Int? = nil, preserveRange: Bool? = nil) {
    let peer = self.peer

    log
      .debug(
        "Loading messages for \(peer) limit: \(limit != nil ? limit.debugDescription : "No limit") preserveRange: \(preserveRange ?? false)"
      )

    do {
      let messagesBatch: [FullMessage] = try db.dbWriter.read { db in
        // base query
        var query = Message
          .including(optional: Message.from)
          .including(all: Message.reactions)
          .asRequest(of: FullMessage.self)
          .order(Column("date").desc)

        query = switch peer {
        case .thread(let id):
          query
            .filter(Column("peerThreadId") == id)

        case .user(let id):
          query
            .filter(Column("peerUserId") == id)
        }

        // limit
        if let limit = limit {
          query = query.limit(limit)
        }

        // range query
        if preserveRange == true {
          query = query.filter(Column("globalId") >= minGlobalId && Column("globalId") <= maxGlobalId)
        }

        return try query.fetchAll(db)
      }

      messages = messagesBatch.reversed()
    } catch {
      Log.shared.error("Failed to get messages \(error)")
    }
  }
}

@MainActor
public final class MessagesPublisher {
  static let shared = MessagesPublisher()

  public struct MessageUpdate {
    public let message: FullMessage
    let peer: Peer
  }

  public struct MessageAdd {
    public let messages: [FullMessage]
    let peer: Peer
  }

  public struct MessageDelete {
    public let messageIds: [Int64]
    let peer: Peer
  }

  public enum UpdateType {
    case add(MessageAdd)
    case update(MessageUpdate)
    case delete(MessageDelete)
    case reload(peer: Peer)
  }

  private let db = AppDatabase.shared
  let publisher = PassthroughSubject<UpdateType, Never>()

  // Static methods to publish update
  func messageAdded(message: Message, peer: Peer) {
    Log.shared.debug("Message added: \(message.messageId)")
    let fullMessage = try? db.reader.read { db in
      try Message
        .filter(Column("globalId") == message.globalId)
        .including(optional: Message.from)
        .including(all: Message.reactions)
        .asRequest(of: FullMessage.self)
        .fetchOne(db)
    }
    guard let fullMessage = fullMessage else {
      Log.shared.error("Failed to get full message")
      return
    }
    publisher.send(.add(MessageAdd(messages: [fullMessage], peer: peer)))
  }

  func messagesDeleted(messageIds: [Int64], peer: Peer) {
    publisher.send(.delete(MessageDelete(messageIds: messageIds, peer: peer)))
  }

  func messageUpdated(message: Message, peer: Peer) {
    Log.shared.debug("Message updated: \(message.messageId)")
    let fullMessage = try? db.reader.read { db in
      try Message
        .filter(Column("globalId") == message.globalId)
        .including(optional: Message.from)
        .including(all: Message.reactions)
        .asRequest(of: FullMessage.self)
        .fetchOne(db)
    }
    guard let fullMessage = fullMessage else {
      Log.shared.error("Failed to get full message")
      return
    }
    publisher.send(.update(MessageUpdate(message: fullMessage, peer: peer)))
  }

  func messagesReload(peer: Peer) {
    publisher.send(.reload(peer: peer))
  }
}
