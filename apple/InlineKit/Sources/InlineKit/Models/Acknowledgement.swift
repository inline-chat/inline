import Foundation
import GRDB
import InlineProtocol

public enum AcknowledgementPersistenceError: Error, Equatable, Sendable {
  case missingChat(Int64)
}

/// One confirmed explicit acknowledgement cursor state per actor and chat.
public struct Acknowledgement: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
  public var chatId: Int64
  public var userId: Int64
  public var maxId: Int64
  public var revision: Int64
  public var cleared: Bool

  public static let databaseTableName = "acknowledgement"
  public static let user = belongsTo(User.self, using: ForeignKey(["userId"], to: ["id"]))

  public enum Columns {
    public static let chatId = Column("chatId")
    public static let userId = Column("userId")
    public static let maxId = Column("maxId")
    public static let revision = Column("revision")
    public static let cleared = Column("cleared")
  }

  public init(
    chatId: Int64,
    userId: Int64,
    maxId: Int64,
    revision: Int64 = 0,
    cleared: Bool = false
  ) {
    self.chatId = chatId
    self.userId = userId
    self.maxId = maxId
    self.revision = revision
    self.cleared = cleared
  }

  /// Negative revisions are reserved for in-memory row projections and are
  /// rejected by every persistence path.
  public var isOptimisticProjection: Bool { revision < 0 }

  /// Returns the target rows affected by an accepted cursor change.
  @discardableResult
  public static func save(_ db: Database, cursor: InlineProtocol.ChatAcknowledgement) throws -> [Int64] {
    guard cursor.chatID > 0, cursor.userID > 0, cursor.maxID > 0, cursor.revision >= 0 else { return [] }
    guard try Chat.fetchOne(db, id: cursor.chatID) != nil else {
      throw AcknowledgementPersistenceError.missingChat(cursor.chatID)
    }

    let previous = try Acknowledgement
      .filter(Columns.chatId == cursor.chatID && Columns.userId == cursor.userID)
      .fetchOne(db)

    if cursor.revision > 0 {
      guard cursor.revision > (previous?.revision ?? 0) else { return [] }
    } else {
      // Compatibility with pre-revision snapshots during a staged rollout.
      guard !cursor.cleared,
            (previous?.revision ?? 0) == 0,
            cursor.maxID > (previous?.maxId ?? 0) else { return [] }
    }
    guard cursor.maxID >= (previous?.maxId ?? 0) else { return [] }

    if cursor.hasUser, cursor.user.id == cursor.userID {
      _ = try User.save(db, user: cursor.user)
    }

    let next = Acknowledgement(
      chatId: cursor.chatID,
      userId: cursor.userID,
      maxId: cursor.maxID,
      revision: cursor.revision,
      cleared: cursor.cleared
    )
    try next.save(db)

    let oldTarget = previous.flatMap { $0.cleared ? nil : $0.maxId }
    let newTarget: Int64? = next.maxId
    return Array(Set([oldTarget, newTarget].compactMap { $0 })).sorted()
  }

  /// Snapshot omission is not a clear. Explicit revisioned tombstones own clear state.
  @discardableResult
  public static func save(
    _ db: Database,
    cursors: [InlineProtocol.ChatAcknowledgement],
    chatId: Int64,
    publishChanges: Bool = false,
    animated: Bool = false,
    publisher: MessagesPublisher? = nil
  ) throws -> [Int64] {
    var affected: Set<Int64> = []
    var accepted: [InlineProtocol.ChatAcknowledgement] = []
    for cursor in cursors where cursor.chatID == chatId {
      let changed = try save(db, cursor: cursor)
      if !changed.isEmpty {
        affected.formUnion(changed)
        accepted.append(cursor)
      }
    }
    let affectedIDs = affected.sorted()
    guard publishChanges, !accepted.isEmpty,
          let chat = try Chat.fetchOne(db, id: chatId) else { return affectedIDs }
    let actorIds = Set(accepted.map(\.userID))
    let users = try User.userInfoQuery().filter(actorIds.contains(Column("id"))).fetchAll(db)
    let usersByID = Dictionary(uniqueKeysWithValues: users.map { ($0.user.id, $0) })
    let changes = accepted.map { cursor in
      FullAcknowledgement(
        acknowledgement: Acknowledgement(
          chatId: cursor.chatID, userId: cursor.userID, maxId: cursor.maxID,
          revision: cursor.revision, cleared: cursor.cleared
        ),
        userInfo: usersByID[cursor.userID]
      )
    }
    // Publish the committed cursor projection; publication never fetches message rows.
    db.afterNextTransaction { _ in
      Task { @MainActor in
        (publisher ?? .shared).acknowledgementsChanged(changes, peer: chat.peerId.toPeer(), animated: animated)
      }
    }
    return affectedIDs
  }
}

public struct FullAcknowledgement: Codable, FetchableRecord, Hashable, Sendable {
  public var acknowledgement: Acknowledgement
  public var userInfo: UserInfo?

  public init(acknowledgement: Acknowledgement, userInfo: UserInfo? = nil) {
    self.acknowledgement = acknowledgement
    self.userInfo = userInfo
  }
}

/// A resident-row projection. Optimistic state is never written to GRDB; a
/// conditional restore prevents an older failure from replacing confirmed state.
public enum AcknowledgementProjection: Equatable, Sendable {
  case replace(FullAcknowledgement)
  case restore(
    chatId: Int64,
    userId: Int64,
    replacingRevision: Int64,
    previous: FullAcknowledgement?
  )
}

public struct AcknowledgementAction: Equatable, Sendable {
  public var clear: Bool
  public var expectedRevision: Int64

  public init(clear: Bool, expectedRevision: Int64) {
    self.clear = clear
    self.expectedRevision = expectedRevision
  }
}

public extension FullMessage {
  /// Presentation includes active rows only; tombstones stay available for same-target reactivation.
  var acknowledgementActors: [FullAcknowledgement] {
    (acknowledgements ?? []).filter { !$0.acknowledgement.cleared }
  }

  func acknowledgementState(for userId: Int64?) -> Acknowledgement? {
    guard let userId, userId > 0 else { return nil }
    return acknowledgements?.first(where: { $0.acknowledgement.userId == userId })?.acknowledgement
  }

  func acknowledgementAction(currentUserId: Int64?) -> AcknowledgementAction? {
    guard let currentUserId, currentUserId > 0,
          message.messageId > 0,
          message.fromId != currentUserId,
          message.status != .sending,
          message.status != .failed,
          !message.isServiceMessage else { return nil }
    let state = currentUserAcknowledgement?.userId == currentUserId
      ? currentUserAcknowledgement
      : acknowledgementState(for: currentUserId)
    // Negative revisions exist only in resident rows while one admitted Ack is
    // awaiting authoritative state. Do not build a second request from it.
    guard state?.isOptimisticProjection != true else { return nil }
    guard message.messageId >= (state?.maxId ?? 0) else { return nil }
    return AcknowledgementAction(
      clear: state?.maxId == message.messageId && state?.cleared == false,
      expectedRevision: state?.maxId == message.messageId ? (state?.revision ?? 0) : 0
    )
  }

  /// Apply an already-committed cursor to a loaded row without fetching it again.
  mutating func applyAcknowledgement(_ cursor: FullAcknowledgement, currentUserId: Int64?) {
    applyAcknowledgement(.replace(cursor), currentUserId: currentUserId)
  }

  mutating func applyAcknowledgement(_ projection: AcknowledgementProjection, currentUserId: Int64?) {
    switch projection {
      case let .replace(cursor):
        guard cursor.acknowledgement.chatId == chatId else { return }
        if cursor.acknowledgement.userId == currentUserId,
           let current = currentUserAcknowledgement,
           !current.isOptimisticProjection,
           !cursor.acknowledgement.isOptimisticProjection {
          if cursor.acknowledgement.revision > 0 {
            guard cursor.acknowledgement.revision >= current.revision else { return }
          } else {
            guard current.revision == 0,
                  cursor.acknowledgement.maxId >= current.maxId else { return }
          }
        }
        replaceAcknowledgement(cursor, userId: cursor.acknowledgement.userId, currentUserId: currentUserId)

      case let .restore(chatId, userId, replacingRevision, previous):
        guard chatId == self.chatId,
              userId == currentUserId,
              replacingRevision < 0,
              currentUserAcknowledgement?.revision == replacingRevision else { return }
        replaceAcknowledgement(previous, userId: userId, currentUserId: currentUserId)
    }
  }

  private mutating func replaceAcknowledgement(
    _ cursor: FullAcknowledgement?,
    userId: Int64,
    currentUserId: Int64?
  ) {
    acknowledgements?.removeAll { $0.acknowledgement.userId == userId }
    if let cursor, cursor.acknowledgement.maxId == message.messageId {
      if acknowledgements == nil { acknowledgements = [] }
      acknowledgements?.append(cursor)
      acknowledgements?.sort { $0.acknowledgement.userId < $1.acknowledgement.userId }
    }
    if userId == currentUserId { currentUserAcknowledgement = cursor?.acknowledgement }
  }

  var withoutAcknowledgements: FullMessage {
    var message = self
    message.acknowledgements = nil
    message.currentUserAcknowledgement = nil
    return message
  }

  var acknowledgementPillWidth: CGFloat {
    let count = acknowledgementActors.count
    guard count > 0 else { return 0 }
    let avatarWidth = 28 + CGFloat(min(count, 3) - 1) * 14
    guard count > 3 else { return avatarWidth }
    return avatarWidth + 2 + AcknowledgementLayout.countWidth(count - 3, includesPlus: true)
  }

  var acknowledgementMinimumPillWidth: CGFloat {
    max(28, 16 + AcknowledgementLayout.countWidth(acknowledgementActors.count))
  }

  var acknowledgementLabel: String {
    let actors = acknowledgementActors
    let confirmedActors = actors.filter { !$0.acknowledgement.isOptimisticProjection }
    let hasPendingActor = confirmedActors.count != actors.count
    guard !confirmedActors.isEmpty else {
      return hasPendingActor ? "Acknowledging through this message" : "Acknowledged through this message"
    }
    let names = confirmedActors.compactMap { $0.userInfo?.user.shortDisplayName }
    let confirmedLabel: String
    if confirmedActors.count == 1, let name = names.first {
      confirmedLabel = "Acknowledged through this message by \(name)"
    } else {
      let shown = Array(names.prefix(3))
      let hiddenCount = confirmedActors.count - shown.count
      if shown.isEmpty {
        confirmedLabel = "Acknowledged through this message by \(confirmedActors.count) people"
      } else {
        let prefix = "Acknowledged through this message by " + shown.joined(separator: ", ")
        confirmedLabel = hiddenCount > 0 ? prefix + ", and \(hiddenCount) more" : prefix
      }
    }
    if hasPendingActor {
      return confirmedLabel + ". Your acknowledgement is syncing"
    }
    return confirmedLabel
  }
}

public enum AcknowledgementLayout {
  /// Both native leaves cap the count font at 11pt. Eight points per monospaced
  /// digit (including the plus) leaves room without changing message wrapping.
  public static func countWidth(_ count: Int, includesPlus: Bool = false) -> CGFloat {
    CGFloat(String(max(0, count)).count + (includesPlus ? 1 : 0)) * 8
  }

  public static func visibleAvatarCount(actorCount: Int, width: CGFloat, availableAvatarCount: Int = .max) -> Int {
    let maximum = max(0, min(3, actorCount, availableAvatarCount))
    for shown in stride(from: maximum, through: 0, by: -1) {
      let remaining = actorCount - shown
      let required = remaining == 0
        ? 14 + CGFloat(shown) * 14
        : 16 + CGFloat(shown) * 14 + countWidth(remaining, includesPlus: shown > 0)
      if width >= required { return shown }
    }
    return 0
  }

  /// First strong letter determines the message edge; neutral content uses the native layout direction.
  public static func isRTL(_ text: String?, fallback: Bool = false) -> Bool {
    for scalar in (text ?? "").unicodeScalars {
      if scalar.value == 0x200F { return true }
      if scalar.value == 0x200E { return false }
      guard CharacterSet.letters.contains(scalar) else { continue }
      switch scalar.value {
      case 0x0590 ... 0x08FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF,
           0x10800 ... 0x10FFF, 0x1E800 ... 0x1E95F:
        return true
      default:
        return false
      }
    }
    return fallback
  }
}
