import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Message via")
struct MessageViaTests {
  private func proto(via: MessageVia?) -> InlineProtocol.Message {
    InlineProtocol.Message.with {
      $0.id = 201
      $0.chatID = 44
      $0.fromID = 9
      $0.date = 1
      $0.peerID.chat.chatID = 44
      $0.message = "Deploy checklist"
      if let via { $0.via = via }
    }
  }

  private let codex = MessageVia.with {
    $0.app = "codex"
    $0.name = "Codex"
  }

  @Test("via is stored with the message and survives durable JSON")
  func storesVia() throws {
    let message = Message(from: proto(via: codex))
    #expect(message.via == codex)
    let payload = try #require(message.contentPayload)
    let restored = try JSONDecoder().decode(Client_MessageContentPayload.self, from: JSONEncoder().encode(payload))
    #expect(restored.via == codex)
    #expect(restored.via.name == "Codex")
  }

  @Test("a plain message has no via")
  func plainMessage() {
    #expect(Message(from: proto(via: nil)).via == nil)
  }

  @Test("a bot signer round-trips through durable JSON")
  func botViaRoundTrip() throws {
    let bot = MessageVia.with { $0.botUserID = 4521 }
    let payload = try #require(Message(from: proto(via: bot)).contentPayload)
    let restored = try JSONDecoder().decode(Client_MessageContentPayload.self, from: JSONEncoder().encode(payload))
    #expect(restored.via.botUserID == 4521)
    #expect(!restored.via.hasName)
  }

  @Test("presentation names known agents and stays generic otherwise")
  func presentation() throws {
    let named = try #require(MessageViaPresentation(via: codex, cachedUser: { _ in nil }))
    #expect(named.label == "Sent via Codex")
    #expect(named.mark == .agent("codex"))
    #expect(named.detail(senderName: "Mo") == "Mo sent this using Codex, an AI agent.")

    // Without a name from the server, a known agent still reads by its proper name.
    let unnamed = try #require(MessageViaPresentation(via: .with { $0.app = "claude-code" }, cachedUser: { _ in nil }))
    #expect(unnamed.label == "Sent via Claude Code")
    let unknown = try #require(MessageViaPresentation(via: .with { $0.app = "future-cli" }, cachedUser: { _ in nil }))
    #expect(unknown.label == "Sent via future-cli")

    let generic = try #require(MessageViaPresentation(via: .with { $0.app = "agent"; $0.name = "an AI agent" }, cachedUser: { _ in nil }))
    #expect(generic.label == "Sent via an AI agent")
    #expect(generic.detail(senderName: "Mo") == "Mo sent this using an AI agent.")

    // A bot this device hasn't loaded reads by the name it had at send time, without a badge.
    let unloadedBot = try #require(MessageViaPresentation(
      via: .with { $0.botUserID = 9; $0.name = "Atlas" },
      cachedUser: { _ in nil }
    ))
    #expect(unloadedBot.label == "Sent via Atlas")
    #expect(unloadedBot.mark == nil)
    #expect(unloadedBot.detail(senderName: "Mo") == "Mo sent this using their bot Atlas.")

    let loadedBot = UserInfo(user: User(id: 9, email: nil, firstName: "Atlas", lastName: nil, username: "atlas_bot"))
    let cached = try #require(MessageViaPresentation(via: .with { $0.botUserID = 9 }, cachedUser: { $0 == 9 ? loadedBot : nil }))
    #expect(cached.mark == .bot(loadedBot))
    #expect(cached.label == "Sent via Atlas")

    #expect(MessageViaPresentation(via: nil, cachedUser: { _ in nil }) == nil)
    #expect(MessageViaPresentation(via: MessageVia(), cachedUser: { _ in nil }) == nil)
  }
}
