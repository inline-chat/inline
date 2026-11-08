import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

/// Offline lab for the @ and ♥ buttons: which message a tap jumps to, when an on-screen item
/// counts as seen, and when the navigator asks the server for missing items.
@MainActor
@Suite("Chat activity navigator")
struct ChatActivityNavigatorTests {
  private let chatId: Int64 = 55

  private actor Recorder {
    private(set) var requests: [ChatActivityNavigator.Request] = []
    func record(_ request: ChatActivityNavigator.Request) { requests.append(request) }
  }

  private func makeNavigator(
    items: [ChatActivityItem],
    counts: (mentions: Int32, reactions: Int32)
  ) throws -> (ChatActivityNavigator, Recorder) {
    let database = AppDatabase.empty()
    let peer = InlineProtocol.Peer.with { $0.chat = .with { $0.chatID = chatId } }
    try database.dbWriter.write { db in
      try Chat(id: chatId, date: .init(timeIntervalSince1970: 1), type: .thread, title: "Lab", spaceId: nil).insert(db)
      try InlineProtocol.Dialog.with {
        $0.peer = peer
        $0.chatID = chatId
        $0.unreadMentionsCount = counts.mentions
        $0.unreadReactionsCount = counts.reactions
      }.saveFull(db)
      for item in items { try item.insert(db) }
    }
    let recorder = Recorder()
    let navigator = ChatActivityNavigator(peerId: .thread(id: chatId), chatId: chatId, database: database) { request, _, _ in
      await recorder.record(request)
    }
    navigator.start()
    return (navigator, recorder)
  }

  private func item(_ id: Int64, _ kind: ChatActivityItem.Kind) -> ChatActivityItem {
    ChatActivityItem(chatId: chatId, messageId: id, kind: kind)
  }

  private func settle(_ ms: Int = 350) async throws {
    try await Task.sleep(for: .milliseconds(ms))
  }

  /// Waits for the recorder to hold at least `count` requests; fixed sleeps flake under load.
  private func requests(_ recorder: Recorder, atLeast count: Int) async throws -> [ChatActivityNavigator.Request] {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      let requests = await recorder.requests
      if requests.count >= count { return requests }
      try await Task.sleep(for: .milliseconds(20))
    }
    return await recorder.requests
  }

  @Test("Taps go to the oldest mention, and the heart to the oldest reaction")
  func jumpOrder() async throws {
    let (navigator, _) = try makeNavigator(
      items: [item(30, .mention), item(10, .mention), item(20, .mention), item(5, .reaction), item(8, .reaction)],
      counts: (3, 2)
    )
    #expect(navigator.state == .init(mentionsCount: 3, reactionsCount: 2))
    #expect(await navigator.nextMessageId() == 10)
    #expect(await navigator.nextReactionMessageId() == 5)
  }

  @Test("Messages on screen for the dwell are read once, mentions and reactions together")
  func dwellReadsOnce() async throws {
    let (navigator, recorder) = try makeNavigator(
      items: [item(10, .mention), item(12, .mention), item(5, .reaction)],
      counts: (2, 1)
    )
    navigator.noteVisible(messageIds: [4, 5, 10, 11])
    #expect(try await requests(recorder, atLeast: 1) == [.read(messageIds: [5, 10])])
    navigator.noteVisible(messageIds: [5, 10, 11]) // still on screen, must not resend
    try await settle()
    #expect(await recorder.requests == [.read(messageIds: [5, 10])])
  }

  @Test("Scrolling past an item faster than the dwell does not read it")
  func quickScrollDoesNotRead() async throws {
    let (navigator, recorder) = try makeNavigator(items: [item(10, .mention)], counts: (1, 0))
    navigator.noteVisible(messageIds: [10])
    try await Task.sleep(for: .milliseconds(60))
    navigator.noteVisible(messageIds: [40, 41])
    try await settle()
    #expect(await recorder.requests.isEmpty)

    navigator.noteVisible(messageIds: [10])
    try await Task.sleep(for: .milliseconds(60))
    navigator.clearVisible() // window resigned / app backgrounded
    try await settle()
    #expect(await recorder.requests.isEmpty)
  }

  @Test("Missing local rows trigger one refill of that kind")
  func refillWhenCountsExceedLocalItems() async throws {
    let (_, recorder) = try makeNavigator(items: [item(10, .mention), item(4, .reaction)], counts: (3, 1))
    #expect(try await requests(recorder, atLeast: 1) == [.refill(.mention)])
    try await settle(100)
    #expect(await recorder.requests == [.refill(.mention)])
  }

  @Test("Mark all sends one request per button kind")
  func markAll() async throws {
    let (navigator, recorder) = try makeNavigator(items: [item(10, .mention), item(5, .reaction)], counts: (1, 1))
    navigator.markAllMentionsRead()
    navigator.markAllReactionsRead()
    let requests = try await requests(recorder, atLeast: 2)
    // Bounded by the newest message this device knows (no chat lastMsgId here, so the newest item).
    #expect(requests.contains(.readAll(.mention, maxId: 10)))
    #expect(requests.contains(.readAll(.reaction, maxId: 10)))
  }
}
