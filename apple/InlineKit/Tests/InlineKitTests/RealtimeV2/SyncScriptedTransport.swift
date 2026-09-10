import AsyncAlgorithms
import InlineProtocol
@testable import RealtimeV2
import Testing

/// Scripted remote messages only: the session, receipt, Sync, UpdatesEngine and
/// GRDB above are real. No test-side scheduler or sync implementation.
actor SyncScriptedTransport: Transport {
  struct Request: Equatable { let from: Int64
    let through: Int64
  }

  nonisolated let events = AsyncChannel<TransportEvent>()
  private(set) var requests: [Request] = []
  func start() async {}
  func stop() async {}
  func finish() {
    events.finish()
  }

  func push(_ updates: [InlineProtocol.Update]) async {
    await events.send(.message(.with {
      $0.body = .message(.with { $0.payload = .update(.with { $0.updates = updates }) })
    }))
  }

  func send(_ message: ClientMessage) async throws {
    guard case let .rpcCall(call) = message.body, case let .getUpdates(input)? = call.input else {
      Issue.record("Unexpected protocol operation")
      return
    }
    requests.append(Request(from: input.startSeq, through: input.seqEnd))
    let result = GetUpdatesResult.with {
      $0.seq = input.seqEnd
      $0.date = 101
      $0.final = true
      $0.resultType = .slice
      $0.skippedSequences = ((input.startSeq + 1) ... input.seqEnd).map { sequence in
        .with { $0.seq = sequence
          $0.reason = .irrelevantToBucket
        }
      }
    }
    await events.send(.message(.with {
      $0.body = .rpcResult(.with { $0.reqMsgID = message.id
        $0.result = .getUpdates(result)
      })
    }))
  }
}
