#if os(macOS)
import InlineKit
import Testing

@testable import InlineUI

@MainActor
@Suite("Quick forward delivery")
struct QuickForwardDeliveryTests {
  private enum Failure: Error { case unavailable }
  enum CancellationStage: Sendable { case beforeStart, comment, forward, transport }

  @Test("cancellation stops the remaining batch", arguments: [
    CancellationStage.beforeStart, .comment, .forward, .transport,
  ])
  func cancellationStopsBatch(at stage: CancellationStage) async {
    let delivery = QuickForwardDelivery()
    let first = Peer.thread(id: 1)
    let second = Peer.thread(id: 2)
    var comments: [Peer] = []
    var forwards: [Peer] = []
    let task = Task { @MainActor in
      if stage == .beforeStart { withUnsafeCurrentTask { $0?.cancel() } }
      return await delivery.send(
        to: [first, second], comment: "context",
        sendComment: { peer, _ in
          comments.append(peer)
          if stage == .comment { withUnsafeCurrentTask { $0?.cancel() } }
          if stage == .transport { throw CancellationError() }
        },
        forward: { peer in
          forwards.append(peer)
          if stage == .forward { withUnsafeCurrentTask { $0?.cancel() } }
        }
      )
    }
    let result = await task.value
    #expect(!result)
    #expect(comments == (stage == .beforeStart ? [] : [first]))
    #expect(forwards == (stage == .forward ? [first] : []))
    #expect(delivery.completedPeers == (stage == .forward ? [first] : []))
    #expect(!delivery.isSending)
    #expect(delivery.errorMessage != nil)
  }

  @Test("comment precedes forwarding for every destination")
  func commentOrder() async {
    let delivery = QuickForwardDelivery()
    let first = Peer.thread(id: 1)
    let second = Peer.thread(id: 2)
    var calls: [String] = []
    let result = await delivery.send(
      to: [first, second], comment: "  context  ",
      sendComment: { peer, text in calls.append("comment \(peer == first ? 1 : 2): \(text)") },
      forward: { peer in calls.append("forward \(peer == first ? 1 : 2)") }
    )
    #expect(result)
    #expect(calls == ["comment 1: context", "forward 1", "comment 2: context", "forward 2"])
    #expect(delivery.completedPeers == [first, second])
    #expect(!delivery.isSending)
  }

  @Test("partial failure retries only unconfirmed forwards and does not repeat acknowledged comments")
  func partialFailure() async {
    let delivery = QuickForwardDelivery()
    let first = Peer.thread(id: 1)
    let second = Peer.thread(id: 2)
    var comments: [Peer] = []
    var forwards: [Peer] = []
    let result = await delivery.send(
      to: [first, second], comment: "context",
      sendComment: { peer, _ in comments.append(peer) },
      forward: { peer in
        forwards.append(peer)
        if peer == second { throw Failure.unavailable }
      }
    )
    #expect(!result)
    #expect(delivery.completedPeers == [first])
    #expect(delivery.errorMessage != nil)
    let retry = await delivery.send(
      to: [first, second], comment: "context",
      sendComment: { peer, _ in comments.append(peer) },
      forward: { peer in forwards.append(peer) }
    )
    #expect(retry)
    #expect(comments == [first, second])
    #expect(forwards == [first, second, second])
    #expect(delivery.errorMessage == nil)
  }

  @Test("comment failure stops that destination before forwarding, while other destinations continue")
  func commentFailure() async {
    let delivery = QuickForwardDelivery()
    let first = Peer.thread(id: 1)
    let second = Peer.thread(id: 2)
    var forwards: [Peer] = []
    let result = await delivery.send(
      to: [first, second], comment: "context",
      sendComment: { peer, _ in if peer == first { throw Failure.unavailable } },
      forward: { peer in forwards.append(peer) }
    )
    #expect(!result)
    #expect(forwards == [second])
    #expect(delivery.commentedPeers == [second])
  }

  @Test("blank comments are omitted and duplicate recipients are not forwarded twice")
  func blankComment() async {
    let delivery = QuickForwardDelivery()
    let peer = Peer.thread(id: 1)
    var comments = 0
    var forwards = 0
    let result = await delivery.send(
      to: [peer, peer], comment: " \n ",
      sendComment: { _, _ in comments += 1 },
      forward: { _ in forwards += 1 }
    )
    #expect(result)
    #expect(comments == 0)
    #expect(forwards == 1)
  }
}
#endif
