import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Block inline actions")
struct BlockInlineActionsTests {
  private func action(_ id: String, _ text: String = "Go") -> MessageAction {
    .with {
      $0.actionID = id
      $0.text = text
      $0.callback = .with { $0.data = Data([1]) }
    }
  }

  @Test("Blocks report the actions they draw, nested ones included")
  func ids() {
    let blocks: [Block] = [
      .with { $0.planProposal = .with { $0.actionIds = ["approve", "keep"] } },
      .with {
        $0.callout = .with {
          $0.children = [.with { $0.approval = .with { $0.actionIds = ["allow"] } }]
        }
      },
      .with { $0.review = .with { $0.findings = [.with { $0.actionID = "fix-1" }, .init()] } },
      .with { $0.nextStep = .with { $0.actionIds = ["yes"] } },
    ]
    #expect(BlockInlineActions.ids(in: blocks) == ["approve", "keep", "allow", "fix-1", "yes"])
  }

  @Test("Rows drop actions blocks draw, and rows left empty")
  func remainingRows() {
    let actions = MessageActions.with {
      $0.rows = [
        .with { $0.actions = [action("approve"), action("keep")] },
        .with { $0.actions = [action("open"), action("approve")] },
      ]
    }
    let rows = BlockInlineActions.remainingRows(actions, drawnInside: ["approve", "keep"])
    #expect(rows.count == 1)
    #expect(rows.first?.actions.map(\.actionID) == ["open"])
    #expect(BlockInlineActions.byID(actions)["keep"]?.text == "Go")
  }

  @Test("Compose text is trimmed and capped")
  func compose() {
    #expect(MessageActionPresentation.composeIntent("  Ship it \n") == .compose("Ship it"))
    #expect(MessageActionPresentation.composeIntent("   ") == .unavailable)
    #expect(MessageActionPresentation.composeIntent(String(repeating: "a", count: 4_001)) == .unavailable)
    let intent = MessageActionPresentation.intent(for: .compose(.with { $0.text = "Explain the plan" }))
    #expect(intent == .compose("Explain the plan"))
  }

  @Test("A stored compose action survives the JSON round trip")
  func codable() throws {
    let stored = MessageAction.with {
      $0.actionID = "ask"
      $0.text = "Ask"
      $0.compose = .with { $0.text = "Why this order?" }
    }
    let decoded = try JSONDecoder().decode(MessageAction.self, from: JSONEncoder().encode(stored))
    #expect(decoded.compose.text == "Why this order?")
  }
}

@Suite("Message compose requests")
struct MessageComposeRequestsTests {
  @Test("A request fills its chat's composer, or only its thread's when posted from the anchor")
  func targets() {
    let parent = Peer.thread(id: 10)
    let thread = Chat(id: 20, date: Date(), type: .thread, title: "Thread", spaceId: nil, parentChatId: 10, parentMessageId: 7)
    let other = Chat(id: 21, date: Date(), type: .thread, title: "Other", spaceId: nil, parentChatId: 10, parentMessageId: 8)

    let inList = MessageComposeRequests.Request(peer: parent, text: "Hi", chatID: 10, messageID: 7)
    #expect(inList.targets(peer: parent, chat: nil))
    #expect(!inList.targets(peer: .thread(id: 20), chat: thread))

    let anchor = MessageComposeRequests.Request(peer: parent, text: "Hi", chatID: 10, messageID: 7, isThreadAnchor: true)
    #expect(!anchor.targets(peer: parent, chat: nil))
    #expect(anchor.targets(peer: .thread(id: 20), chat: thread))
    #expect(!anchor.targets(peer: .thread(id: 21), chat: other))
  }
}
