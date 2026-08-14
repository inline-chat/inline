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
    #expect(NudgeButtonState.tapSuppressionDelay == 0.2)
  }

  @Test("Suppresses taps after a hold attempt or completed hold")
  func tapSuppressionPolicy() async throws {
    #expect(!NudgeButtonState.shouldSuppressTap(holdDuration: 0.19, completed: false))
    #expect(NudgeButtonState.shouldSuppressTap(holdDuration: 0.2, completed: false))
    #expect(NudgeButtonState.shouldSuppressTap(holdDuration: 0, completed: true))
  }
}
