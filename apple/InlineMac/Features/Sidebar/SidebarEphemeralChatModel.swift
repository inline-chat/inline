import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation
import Translation

@MainActor
@Observable
final class SidebarEphemeralChatModel {
  private struct Projection {
    let parentSnapshot: ChatListItemSnapshot?
    let itemSnapshot: ChatListItemSnapshot?
    let kind: ChatListItem.Kind

    var parentItem: SidebarViewModel.Item? {
      parentSnapshot.map { SidebarViewModel.Item(snapshot: $0) }
    }

    var item: SidebarViewModel.Item? {
      itemSnapshot.map { SidebarViewModel.Item(snapshot: $0, kind: kind) }
    }

    static let empty = Self(parentSnapshot: nil, itemSnapshot: nil, kind: .thread)
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
  @ObservationIgnored private var translationCancellable: AnyCancellable?
  @ObservationIgnored private var translationLanguageCancellable: AnyCancellable?
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var retryAttempt = 0

  var peer: Peer? {
    scope?.peer
  }

  init(db: AppDatabase = .shared) {
    self.db = db
    translationCancellable = TranslationState.shared.subject.sink { [weak self] event in
      guard let self else { return }
      let (peer, _) = event
      guard projection.itemSnapshot?.peer == peer || projection.parentSnapshot?.peer == peer else { return }
      projection = Projection(
        parentSnapshot: projection.parentSnapshot,
        itemSnapshot: projection.itemSnapshot,
        kind: projection.kind
      )
      if let scope {
        bind(scope)
      }
    }
    translationLanguageCancellable = NotificationCenter.default
      .publisher(for: .translationLanguageChanged)
      .sink { [weak self] _ in
        guard let self, let scope else { return }
        bind(scope)
      }
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
    retryTask?.cancel()
    retryTask = nil
    retryAttempt = 0
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
    retryTask?.cancel()
    retryTask = nil
    retryAttempt = 0
  }

  private func bind(_ scope: Scope) {
    guard self.scope == scope else { return }
    cancellable?.cancel()
    cancellable = nil
    retryTask?.cancel()
    retryTask = nil

    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarEphemeralChat")
    #endif

    cancellable = ValueObservation
      .tracking { db in
        let snapshots = try ChatListDatabaseQuery.fetchSnapshots(
          db,
          spaceID: scope.spaceId,
          includeSpaceChatsInHome: scope.includeSpaceChatsInHome,
          translationLanguage: UserLocale.getCurrentLanguage()
        )
        let chat = snapshots.first { $0.peer == scope.peer }
        let parent = chat?.parentChatID.flatMap { parentChatID in
          snapshots.first { $0.peer == .thread(id: parentChatID) }
        }
        let kind: ChatListItem.Kind
        if scope.spaceId != nil, case .user = scope.peer {
          kind = .contact
        } else {
          kind = .thread
        }
        return Projection(
          parentSnapshot: parent,
          itemSnapshot: chat,
          kind: kind
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self, self.scope == scope else { return }
          guard case let .failure(error) = completion else { return }
          log.error("Temporary sidebar chat observation failed: \(Self.safeErrorName(error))")
          scheduleRetry(for: scope)
        },
        receiveValue: { [weak self] projection in
          // Publish the pair atomically so no observation can render the reply
          // as an orphan root or produce a second parent-only settle.
          guard let self, self.scope == scope else { return }
          retryAttempt = 0
          retryTask?.cancel()
          retryTask = nil
          self.projection = projection
        }
      )
  }

  private func scheduleRetry(for scope: Scope) {
    guard retryTask == nil, self.scope == scope else { return }
    retryAttempt &+= 1
    let delay = min(pow(2, Double(min(retryAttempt - 1, 5))) * 0.25, 8)
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard Task.isCancelled == false, let self, self.scope == scope else { return }
      retryTask = nil
      bind(scope)
    }
  }

  private nonisolated static func safeErrorName(_ error: Error) -> String {
    if error is RowDecodingError {
      return "RowDecodingError"
    }
    if let error = error as? DatabaseError {
      return "DatabaseError(\(error.resultCode.rawValue))"
    }
    return String(reflecting: type(of: error))
  }
}
