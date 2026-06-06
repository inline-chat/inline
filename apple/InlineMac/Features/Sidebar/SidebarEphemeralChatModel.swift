import Combine
import GRDB
import InlineKit
import Logger
import Observation

@MainActor
@Observable
final class SidebarEphemeralChatModel {
  struct Scope: Equatable {
    let peer: Peer
    let spaceId: Int64?
    let includeSpaceChatsInHome: Bool
  }

  var item: SidebarViewModel.Item?

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
    item = nil

    bind(scope)
  }

  func isScoped(spaceId: Int64?, includeSpaceChatsInHome: Bool) -> Bool {
    guard let scope else { return true }
    return scope.spaceId == spaceId && scope.includeSpaceChatsInHome == includeSpaceChatsInHome
  }

  func cancel() {
    scope = nil
    item = nil
    cancellable?.cancel()
    cancellable = nil
  }

  private func bind(_ scope: Scope) {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarEphemeralChat")
    #endif

    cancellable = ValueObservation
      .tracking { db in
        let chat = try Self.request(scope: scope)
          .fetchOne(db)
        let title: String?
        let parentTitle: String?
        if let itemChat = chat?.chat {
          title = try ReplyThreadTitleFallback.title(for: itemChat, db: db)
          parentTitle = try ReplyThreadTitleFallback.parentTitlesByChatId(for: [itemChat], db: db)[itemChat.id]
        } else {
          title = nil
          parentTitle = nil
        }
        return chat.map { ChatListItem(chatItem: $0, titleOverride: title, parentTitle: parentTitle) }
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Temporary sidebar chat observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] chat in
          self?.item = chat.flatMap { SidebarViewModel.Item(listItem: $0) }
        }
      )
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
