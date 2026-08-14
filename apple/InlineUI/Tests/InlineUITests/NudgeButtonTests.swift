import Testing

@testable import InlineUI

@Suite("NudgeButton")
struct NudgeButtonTests {
  @Test("Uses the expected regular and urgent Nudge text")
  func nudgeTextConstants() async throws {
    #expect(NudgeButtonState.nudgeText == "👋")
    #expect(NudgeButtonState.urgentNudgeText == "🚨")
  }

  @Test("Uses a deliberate hold without repeated progress ticks")
  func holdTimingConstants() async throws {
    #expect(NudgeButtonState.holdDuration == 1.2)
    #expect(NudgeButtonState.maximumHoldMovement == 44)
  }

  @Test("Suppresses only the click that follows a completed hold")
  func tapSuppressionPolicy() async throws {
    #expect(!NudgeButtonState.shouldSuppressTap(completed: false))
    #expect(NudgeButtonState.shouldSuppressTap(completed: true))
  }
}
