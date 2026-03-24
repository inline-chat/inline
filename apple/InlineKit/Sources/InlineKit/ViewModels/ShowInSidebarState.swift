import Combine
import Foundation
import GRDB

@MainActor
public final class ShowInSidebarState: ObservableObject {
  @Published public private(set) var isHiddenLinkedThread = false

  private let peer: Peer
  private let db: AppDatabase
  private var dialogCancellable: AnyCancellable?

  public init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    bind()
  }

  private func bind() {
    guard peer.isThread else {
      isHiddenLinkedThread = false
      dialogCancellable = nil
      return
    }

    db.warnIfInMemoryDatabaseForObservation("ShowInSidebarState.dialog")
    dialogCancellable = ValueObservation
      .tracking { db in
        try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: self.peer))
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] dialog in
          self?.isHiddenLinkedThread = dialog?.sidebarVisible == false
        }
      )
  }
}
