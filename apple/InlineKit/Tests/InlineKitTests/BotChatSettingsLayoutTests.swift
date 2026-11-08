import Foundation
@testable import InlineKit
import Testing

@Suite("Agent Settings layout")
struct BotChatSettingsLayoutTests {
  private typealias Item = BotChatSettingsModel.Item

  private func item(
    _ id: String,
    label: String? = nil,
    disabledReason: String? = nil,
    control: BotChatSettingsModel.Control = .button
  ) -> Item {
    Item(
      id: id,
      label: label,
      description: nil,
      isDisabled: disabledReason != nil,
      disabledReason: disabledReason,
      control: control
    )
  }

  private func document(_ sections: [(String, [Item])]) -> BotChatSettingsModel.Document {
    .init(
      version: 1,
      revision: "r",
      sections: sections.map { .init(id: $0.0, title: $0.0.capitalized, description: nil, items: $0.1) }
    )
  }

  private var model: Item {
    item("agent.model", label: "Model", control: .select(value: "a", options: []))
  }

  @Test("moves usage windows and context into meters, compact beside context")
  func meters() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let layout = BotChatSettingsLayout(
      document: document([
        ("usage", [
          item("account.usage.window:300:42:1003600:0", label: "5-hour limit", control: .info(text: "42% used", tone: .neutral)),
          item("account.usage.window:10080:95:0:1", label: "Weekly", control: .info(text: "95% used", tone: .warning)),
        ]),
        ("agent", [model]),
        ("session", [
          item("session.context:120000:200000", label: "Context window", control: .info(text: "60% full", tone: .neutral)),
          item("session.compact", label: "Compact context"),
        ]),
      ]),
      now: now
    )

    #expect(layout.sections.map(\.id) == ["agent"])
    #expect(layout.meters.map(\.title) == ["5-hour limit", "Weekly", "Context"])
    #expect(layout.meters.map(\.value) == ["42%", "95%", "60%"])
    #expect(layout.meters[0].detail != nil)
    #expect(layout.meters[1].detail == nil)
    #expect(layout.meters[1].isHigh)
    #expect(layout.meters[2].detail == "120k / 200k")
    #expect(layout.contextAction?.id == "session.compact")
  }

  @Test("keeps compact in its section until context is reported")
  func compactWithoutContext() {
    let layout = BotChatSettingsLayout(document: document([("session", [item("session.compact", label: "Compact context")])]))

    #expect(layout.contextAction == nil)
    #expect(layout.sections.first?.items.map(\.id) == ["session.compact"])
    #expect(!layout.hasUsage)
  }

  @Test("hides what another source shows and drops emptied sections")
  func hiding() {
    let layout = BotChatSettingsLayout(
      document: document([
        ("agent", [model, item("agent.permissions", label: "Permissions", control: .select(value: "a", options: []))]),
        ("workspace", [item("workspace.folder", label: "Folder", control: .info(text: "inline", tone: .neutral))]),
      ]),
      hiding: ["agent.model", "workspace.folder"]
    )

    #expect(layout.sections.map(\.id) == ["agent"])
    #expect(layout.sections.first?.items.map(\.id) == ["agent.permissions"])
  }

  @Test("one access note when every locked choice shares a reason")
  func accessNote() {
    let reason = "Only Mo can change this."
    let shared = BotChatSettingsLayout(document: document([
      ("agent", [item("a", disabledReason: reason), item("b", disabledReason: reason)]),
      ("usage", [item("account.usage.window:300:10:0:0", label: "5-hour limit", control: .info(text: "10%", tone: .neutral))]),
    ]))
    let distinct = BotChatSettingsLayout(document: document([
      ("agent", [item("a", disabledReason: reason), item("b", disabledReason: "Another reason.")]),
    ]))
    let mostly = BotChatSettingsLayout(document: document([
      ("agent", [item("a", disabledReason: reason), item("b", disabledReason: reason)]),
      ("workspace", [item("folder", disabledReason: "The folder is fixed.")]),
    ]))
    let single = BotChatSettingsLayout(document: document([
      ("workspace", [item("folder", disabledReason: "The folder is fixed.")]),
    ]))

    #expect(shared.accessNote == reason)
    #expect(distinct.accessNote == nil)
    #expect(mostly.accessNote == reason)
    #expect(single.accessNote == nil)
  }

  @Test("keeps a v1 usage summary out of the choices")
  func usageSummary() {
    let layout = BotChatSettingsLayout(document: document([
      ("account.usage", [item("account.usage", label: "Usage", control: .info(text: "12% used", tone: .neutral))]),
    ]))

    #expect(layout.sections.isEmpty)
    #expect(layout.usageSummary?.id == "account.usage")
    #expect(layout.hasUsage)
  }
}
