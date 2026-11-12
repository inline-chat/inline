import Testing
@testable import ChatListCore

@MainActor
struct ChatListHistoryDemandTests {
  @Test func `coverage only progress can explicitly rearm without repeated streaming demands`() throws {
    let session = ChatListSession<Int, Int>(viewport: .init(width: 400, height: 400))
    let snapshot = ChatListSnapshot(context: session.layoutContext,
      items: (0 ..< 10).map { ChatListItem(id: $0, revision: 0, content: $0, height: 100) },
      history: .init(hasOlder: true))
    var demands = 0
    session.onHistoryDemand = { if $0 == .older { demands += 1 } }
    try session.apply(snapshot, intent: .reading(.init(id: 0)), animation: .none, at: 0)
    session.didPresent()
    #expect(demands == 1)
    try session.apply(snapshot, animation: .none, at: 1)
    session.didPresent()
    #expect(demands == 1)
    session.rearmHistoryDemand(at: .older)
    try session.apply(snapshot, animation: .none, at: 2)
    session.didPresent()
    #expect(demands == 2)
  }
}
