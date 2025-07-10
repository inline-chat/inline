import Combine
import Foundation
import GRDB
import Logger

public final class CompactSpaceList: ObservableObject, @unchecked Sendable {
  private let log = Log.scoped("CompactSpaceList")

  @Published public private(set) var spaces: [Space] = []
  public var cancellables: Set<AnyCancellable> = []

  public var db: AppDatabase
  public init(db: AppDatabase) {
    self.db = db
    start()
  }

  public func start() {
    ValueObservation
      .tracking { db in
        try Space.fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in self.log.error("Failed to get spaces \(error)") },
        receiveValue: { [weak self] spaces in
          self?.spaces = spaces
        }
      )
      .store(in: &cancellables)
  }
}
