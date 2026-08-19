import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Realtime update diagnostics")
struct RealtimeUpdateDiagnosticsTests {
  @Test("reports stable update kinds without reflecting payloads")
  func stableKinds() {
    #expect(RealtimeUpdateDiagnostics.kind(of: nil) == "missing")
    #expect(
      RealtimeUpdateDiagnostics.kind(of: .updateReadMaxID(UpdateReadMaxId())) ==
        "updateReadMaxID"
    )
    #expect(
      RealtimeUpdateDiagnostics.kind(of: .markAsUnread(UpdateMarkAsUnread())) ==
        "markAsUnread"
    )
    #expect(
      RealtimeUpdateDiagnostics.kind(of: .updateMessageID(UpdateMessageId())) ==
        "updateMessageID"
    )
    #expect(
      RealtimeUpdateDiagnostics.kind(of: .newMessage(UpdateNewMessage())) ==
        "newMessage"
    )
  }
}
