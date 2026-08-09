import Foundation
@testable import InlineKit
import Testing

@Suite("ApiClient cancellation mapping")
struct ApiClientCancellationMappingTests {
  @Test("structured task cancellation remains cancellation")
  func taskCancellation() {
    let mapped = ApiClient.normalizeTransportError(CancellationError())
    #expect(mapped is CancellationError)
  }

  @Test("URLSession cancellation becomes structured cancellation")
  func urlSessionCancellation() {
    let mapped = ApiClient.normalizeTransportError(URLError(.cancelled))
    #expect(mapped is CancellationError)
  }

  @Test("genuine transport failures retain legacy network error behavior")
  func networkFailureCompatibility() throws {
    for code in [URLError.notConnectedToInternet, .timedOut, .networkConnectionLost] {
      let mapped = ApiClient.normalizeTransportError(URLError(code))
      let apiError = try #require(mapped as? APIError)
      guard case .networkError = apiError else {
        Issue.record("Expected APIError.networkError for \(code)")
        continue
      }
    }
  }

  @Test("unknown failures retain legacy network error behavior")
  func unknownFailureCompatibility() throws {
    struct UnexpectedFailure: Error {}
    let mapped = ApiClient.normalizeTransportError(UnexpectedFailure())
    let apiError = try #require(mapped as? APIError)
    guard case .networkError = apiError else {
      Issue.record("Expected APIError.networkError")
      return
    }
  }
}
