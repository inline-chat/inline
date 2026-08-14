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
    #expect(NudgeButtonState.iOSHoldDuration == 0.5)
    #expect(NudgeButtonState.iOSHoldDuration <= 2.0)
    #expect(NudgeButtonState.macOSHoldDuration == 1.2)
    #expect(NudgeButtonState.maximumHoldMovement == 44)
  }

  @Test("Every release clears the completed hold so later holds can begin")
  func holdReleaseState() async throws {
    let incompleteRelease = NudgeButtonState.releaseState(completed: false)
    #expect(!incompleteRelease.suppressNextTap)
    #expect(!incompleteRelease.completedCurrentHold)

    let completedRelease = NudgeButtonState.releaseState(completed: true)
    #expect(completedRelease.suppressNextTap)
    #expect(!completedRelease.completedCurrentHold)
  }
}
