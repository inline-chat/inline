import Testing

@testable import InlineUI

@Suite("NudgeButton")
struct NudgeButtonTests {
  @Test("Uses default attention target when name is missing")
  func attentionTargetFallsBack() async throws {
    #expect(NudgeButtonState.attentionTarget(displayName: nil) == "their")
    #expect(NudgeButtonState.attentionTarget(displayName: "") == "their")
  }

  @Test("Uses possessive form for attention target when name is present")
  func attentionTargetUsesName() async throws {
    #expect(NudgeButtonState.attentionTarget(displayName: "Riley") == "Riley's")
  }

  @Test("Uses the expected nudge text")
  func nudgeTextConstant() async throws {
    #expect(NudgeButtonState.nudgeText == "👋")
  }
}
