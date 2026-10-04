import Foundation
import InlineConfig
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Agent activity classification")
struct QuietAgentActivityTests {
  @Test("agent activity requires an explicit opt-in")
  func defaultsOff() {
    let suite = "agent-activity-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!AgentActivityFeature.isEnabled(in: defaults))
    defaults.set(true, forKey: AgentActivityFeature.preferenceKey)
    #expect(AgentActivityFeature.isEnabled(in: defaults))
    defaults.set(false, forKey: AgentActivityFeature.preferenceKey)
    #expect(!AgentActivityFeature.isEnabled(in: defaults))
  }

  @Test("recognizes only an explicit standalone agent disclosure")
  func requiresStandaloneAgentMarker() {
    var message = Message(
      messageId: 1, fromId: 2, date: Date(), text: "Activity",
      peerUserId: nil, peerThreadId: 3, chatId: 3
    )
    func content(_ activity: BlockDisclosure.ActivityKind, extraParagraph: Bool = false) -> BlockContentPayload? {
      BlockContentPayload(.with {
        $0.blocks = [.with { $0.kind = .disclosure(.with { $0.activityKind = activity }) }]
        if extraParagraph { $0.blocks.append(.with { $0.kind = .paragraph(.init()) }) }
      })
    }
    message.blockContentPayload = content(.tool)
    #expect(!message.isQuietAgentActivity)
    #expect(message.displayBlockContentPayload(agentActivityEnabled: false) != nil)
    message.blockContentPayload = content(.agent)
    #expect(message.isQuietAgentActivity)
    #expect(message.displayBlockContentPayload(agentActivityEnabled: false) == nil)
    #expect(message.displayBlockContentPayload(agentActivityEnabled: true) != nil)
    #expect(message.blockContentPayload != nil)
    message.blockContentPayload = content(.agent, extraParagraph: true)
    #expect(!message.isQuietAgentActivity)
    message.blockContentPayload = content(.agent)
    message.documentId = 8
    #expect(!message.isQuietAgentActivity)
  }
}
