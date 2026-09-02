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
#if DEBUG
    db.warnIfInMemoryDatabaseForObservation("CompactSpaceList.spaces")
#endif
    let log = log
    ValueObservation
      .tracking { db in
        try Space.catalogActive().fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { completion in
          if case let .failure(error) = completion {
            log.error("Failed to get spaces", error: error)
          }
        },
        receiveValue: { [weak self] spaces in
          self?.spaces = spaces
        }
      )
      .store(in: &cancellables)
  }
}
