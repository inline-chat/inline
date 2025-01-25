import Foundation

class MockMessageCache: @unchecked Sendable {
  static let shared = MockMessageCache()
  var messages: [MockMessage] = []

  func add(_ message: MockMessage) {
    messages.append(message)
  }

  func update(id: String, status: MockMessage.Status) {
    if let index = messages.firstIndex(where: { $0.id == id }) {
      messages[index].status = status
    }
  }

  func remove(id: String) {
    messages.removeAll { $0.id == id }
  }
}

struct MockMessage {
  enum Status {
    case sending
    case sent
    case failed
  }

  let id: String
  let text: String
  var status: Status
}

public struct MockMessageTransaction: Transaction, Codable, Sendable {
  typealias R = Void

  public let id: String
  let text: String
  var config = TransactionConfig.noRetry
  var date = Date()

  let shouldSucceed: Bool
  let executionDelay: Double

  init(
    id: String,
    text: String,

    shouldSucceed: Bool = true,
    executionDelay: Double = 0
  ) {
    self.id = id
    self.text = text

    self.shouldSucceed = shouldSucceed
    self.executionDelay = executionDelay
  }

  func optimistic() {
    MockMessageCache.shared.add(
      MockMessage(
        id: id,
        text: text,
        status: .sending
      )
    )
  }

  func execute() async throws {
    if executionDelay > 0 {
      try await Task.sleep(nanoseconds: UInt64(executionDelay * 1_000_000_000))
    }

    if !shouldSucceed {
      throw MockError.failed
    }
  }

  func didSucceed(result: Void) async {
    MockMessageCache.shared.update(id: id, status: .sent)
  }

  func didFail(error: Error?) async {
    MockMessageCache.shared.update(id: id, status: .failed)
  }

  func rollback() async {
    MockMessageCache.shared.remove(id: id)
  }
}

enum MockError: Error {
  case failed
}
