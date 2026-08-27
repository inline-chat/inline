import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("Local thread command service")
struct LocalThreadCommandServiceTests {
  @Test("creates an unanchored child and opens its sidebar membership")
  func createAndOpen() async throws {
    let recorder = LocalThreadSenderRecorder()

    let result = try await LocalThreadCommandService.createAndOpen(parentChatId: 42) { transaction in
      try await recorder.send(transaction)
    }

    #expect(result == LocalThreadCommandResult(peer: .thread(id: 84), didOpenInSidebar: true))
    #expect(await recorder.parentChatId == 42)
    #expect(await recorder.parentMessageId == nil)
    #expect(await recorder.methods == [
      .createSubthread,
      .updateDialogFollowMode,
      .showInChatList,
      .updateDialogOpen,
    ])
  }

  @Test("continues sidebar mutations and reports a partial failure")
  func partialSidebarFailure() async throws {
    let recorder = LocalThreadSenderRecorder(failingMethod: .showInChatList)

    let result = try await LocalThreadCommandService.createAndOpen(parentChatId: 42) { transaction in
      try await recorder.send(transaction)
    }

    #expect(result.peer == .thread(id: 84))
    #expect(result.didOpenInSidebar == false)
    #expect(await recorder.methods == [
      .createSubthread,
      .updateDialogFollowMode,
      .showInChatList,
      .updateDialogOpen,
    ])
  }
}

private enum LocalThreadSenderError: Error {
  case failed
}

private actor LocalThreadSenderRecorder {
  private(set) var methods: [InlineProtocol.Method] = []
  private(set) var parentChatId: Int64?
  private(set) var parentMessageId: Int64?
  private let failingMethod: InlineProtocol.Method?

  init(failingMethod: InlineProtocol.Method? = nil) {
    self.failingMethod = failingMethod
  }

  func send(_ transaction: any Transaction2) throws -> RpcResult.OneOf_Result? {
    methods.append(transaction.method)
    if let create = transaction as? CreateSubthreadTransaction {
      parentChatId = create.context.parentChatId
      parentMessageId = create.context.parentMessageId
    }
    if transaction.method == failingMethod {
      throw LocalThreadSenderError.failed
    }
    guard transaction.method == .createSubthread else { return nil }

    return .createSubthread(.with {
      $0.chat = .with { $0.id = 84 }
    })
  }
}
