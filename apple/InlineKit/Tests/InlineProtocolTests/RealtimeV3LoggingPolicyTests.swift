import Foundation
import Testing

@testable import InlineProtocol

@Suite("Realtime V3 logging policy")
struct RealtimeV3LoggingPolicyTests {
  @Test("routine connection endings stay out of production logs")
  func routineConnectionEndingsAreDebugOnly() {
    #expect(InlineProtocolV3Connection.failureLogLevel(for: CancellationError()) == .debug)
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: URLError(.networkConnectionLost)
      ) == .debug
    )
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: InlineProtocolV3ConnectionError.closed
      ) == .debug
    )
  }

  @Test("recoverable pressure and timeout remain warnings")
  func recoverablePressureRemainsWarning() {
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: InlineProtocolV3ConnectionError.timeout
      ) == .warning
    )
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: InlineProtocolV3ConnectionError.updateBufferOverflow
      ) == .warning
    )
  }

  @Test("authorization invalidation is elevated once by the transport owner")
  func authorizationInvalidationIsNotDuplicated() {
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: InlineProtocolV3ConnectionError.authorizationInvalidated
      ) == .debug
    )
  }

  @Test("protocol and credential failures remain errors")
  func protocolFailuresRemainErrors() {
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: InlineProtocolV3ConnectionError.invalidKey
      ) == .error
    )
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: InlineProtocolV3ConnectionError.protocolFailure
      ) == .error
    )
    #expect(
      InlineProtocolV3Connection.failureLogLevel(
        for: InlineProtocolV3ConnectionError.unexpectedResponse
      ) == .error
    )
  }
}
