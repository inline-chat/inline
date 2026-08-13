import Combine
import GRDB
import InlineKit
import Logger
import Observation

@MainActor
@Observable
final class SidebarEphemeralChatModel {
  private struct Projection {
    let parentItem: SidebarViewModel.Item?
    let item: SidebarViewModel.Item?

    static let empty = Self(parentItem: nil, item: nil)
  }

  struct Scope: Equatable {
    let peer: Peer
    let spaceId: Int64?
    let includeSpaceChatsInHome: Bool
  }

  private var projection = Projection.empty

  var item: SidebarViewModel.Item? { projection.item }
  var parentItem: SidebarViewModel.Item? { projection.parentItem }

  @ObservationIgnored private let db: AppDatabase
  @ObservationIgnored private let log = Log.scoped("SidebarEphemeralChat")
  @ObservationIgnored private var scope: Scope?
  @ObservationIgnored private var cancellable: AnyCancellable?

  var peer: Peer? {
    scope?.peer
  }

  init(db: AppDatabase = .shared) {
    self.db = db
  }

  /// Read-only preview slot for the selected chat. Promotion to a real sidebar
  /// item must happen through explicit open/order transactions in the view.
  func setScope(peer: Peer?, spaceId: Int64?, includeSpaceChatsInHome: Bool) {
    guard let peer else {
      cancel()
      return
    }

    let scope = Scope(
      peer: peer,
      spaceId: spaceId,
      includeSpaceChatsInHome: includeSpaceChatsInHome
    )
    guard self.scope != scope else { return }
    self.scope = scope
    cancellable?.cancel()
    cancellable = nil
    projection = .empty

    bind(scope)
  }

  func isScoped(spaceId: Int64?, includeSpaceChatsInHome: Bool) -> Bool {
    guard let scope else { return true }
    return scope.spaceId == spaceId && scope.includeSpaceChatsInHome == includeSpaceChatsInHome
  }

  func cancel() {
    scope = nil
    projection = .empty
    cancellable?.cancel()
    cancellable = nil
  }

  private func bind(_ scope: Scope) {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarEphemeralChat")
    #endif

    cancellable = ValueObservation
      .tracking { db in
        let chat = try Self.request(scope: scope).fetchOne(db)
        let parent: HomeChatItem?
        if let parentChatID = chat?.chat?.parentChatId {
          parent = try Self.request(scope: Scope(
            peer: .thread(id: parentChatID),
            spaceId: scope.spaceId,
            includeSpaceChatsInHome: scope.includeSpaceChatsInHome
          )).fetchOne(db)
        } else {
          parent = nil
        }
        return Projection(
          parentItem: try parent.flatMap { try Self.sidebarItem($0, db: db) },
          item: try chat.flatMap { try Self.sidebarItem($0, db: db) }
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Temporary sidebar chat observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] projection in
          // Publish the pair atomically so no observation can render the reply
          // as an orphan root or produce a second parent-only settle.
          self?.projection = projection
        }
      )
  }

  private nonisolated static func sidebarItem(
    _ homeItem: HomeChatItem,
    db: Database
  ) throws -> SidebarViewModel.Item? {
    let title: String?
    let parentTitle: String?
    if let chat = homeItem.chat {
      title = try ReplyThreadTitleFallback.title(for: chat, db: db)
      parentTitle = try ReplyThreadTitleFallback.parentTitlesByChatId(
        for: [chat],
        db: db
      )[chat.id]
    } else {
      title = nil
      parentTitle = nil
    }
    return SidebarViewModel.Item(listItem: ChatListItem(
      chatItem: homeItem,
      titleOverride: title,
      parentTitle: parentTitle
    ))
  }

  private nonisolated static func request(scope: Scope) -> QueryInterfaceRequest<HomeChatItem> {
    var request = HomeChatItem
      .all()
      .filter(
        sql: "\"dialog\".\"id\" = ?",
        arguments: StatementArguments([Dialog.getDialogId(peerId: scope.peer)])
      )

    if let spaceId = scope.spaceId {
      request = request.filter(
        sql: """
        ("dialog"."spaceId" = ? OR "chat"."spaceId" = ? OR "dialog"."peerUserId" IN (
          SELECT "member"."userId"
          FROM "member"
          WHERE "member"."spaceId" = ?
        ))
        """,
        arguments: StatementArguments([spaceId, spaceId, spaceId])
      )
    } else if scope.includeSpaceChatsInHome == false {
      request = request.filter(sql: #"COALESCE("dialog"."spaceId", "chat"."spaceId") IS NULL"#)
    }

    return request
  }
}
