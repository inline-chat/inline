import Auth
import Foundation
@testable import InlineKit
import Testing

@Suite("ApiClient release safety", .serialized)
struct ApiClientReleaseSafetyTests {
  @Test("macOS session metadata uses the process host name")
  @MainActor
  func macOSSessionMetadataUsesProcessHostName() throws {
    #if os(macOS)
      let sessionInfo = try #require(SessionInfo.get())
      #expect(sessionInfo.deviceName == ProcessInfo.processInfo.hostName)
    #endif
  }

  @Test("invite code checks keep the code in POST JSON")
  func inviteCodeRequestBoundary() async throws {
    await SuccessfulRequestProbe.shared.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SuccessfulURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    _ = try await ApiClient(
      urlSession: session,
      auth: Auth.mocked(authenticated: false).handle
    ).checkInviteCode("invite-sentinel")
    let capturedRequest = await SuccessfulRequestProbe.shared.capturedRequest()
    let request = try #require(capturedRequest)

    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/checkInviteCode")
    #expect(request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    // URLSession converts the intercepted body into an internal upload stream on Darwin.
    // Validate the emitted body length here and the exact builder payload below.
    let expectedRequest = try ApiClient.makeJSONPostRequest(
      .checkInviteCode,
      body: ["inviteCode": "invite-sentinel"],
      baseURL: "http://localhost:8000/v1"
    )
    let data = try #require(expectedRequest.httpBody)
    #expect(request.value(forHTTPHeaderField: "Content-Length") == String(data.count))
    let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(decoded == ["inviteCode": "invite-sentinel"])
  }

  @Test("code login never falls back to HTTP when native login is unavailable")
  func codeLoginFailsClosedWithoutNativeLogin() async throws {
    await SuccessfulRequestProbe.shared.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SuccessfulURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = ApiClient(
      urlSession: session,
      auth: Auth.mocked(authenticated: false).handle,
      nativeLoginAvailable: false
    )

    await #expect(throws: InlineProtocolNativeLoginError.unavailable) {
      _ = try await client.sendCode(email: "person@example.com")
    }
    await #expect(throws: InlineProtocolNativeLoginError.unavailable) {
      _ = try await client.sendSmsCode(phoneNumber: "+15555550100")
    }
    await #expect(throws: InlineProtocolNativeLoginError.unavailable) {
      _ = try await client.verifyCode(code: "123456", email: "person@example.com")
    }
    await #expect(throws: InlineProtocolNativeLoginError.unavailable) {
      _ = try await client.verifySmsCode(code: "123456", phoneNumber: "+15555550100")
    }
    #expect(await SuccessfulRequestProbe.shared.capturedRequest() == nil)
  }

  @Test("provider redemption and compensating bearer logout have explicit deadlines")
  func loginNetworkDeadlines() async throws {
    let providerRequest = try ApiClient.makeJSONPostRequest(
      .providerAuthRedeem,
      body: ["ticket": "ticket", "code_verifier": "verifier"],
      baseURL: "https://release.invalid/v1",
      timeoutInterval: 15
    )
    #expect(providerRequest.timeoutInterval == 15)

    await SuccessfulRequestProbe.shared.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SuccessfulURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    _ = try await ApiClient(urlSession: session).logout(bearerToken: "cleanup-token")
    let cleanupRequest = try #require(await SuccessfulRequestProbe.shared.capturedRequest())
    #expect(cleanupRequest.timeoutInterval == 2)
    #expect(cleanupRequest.value(forHTTPHeaderField: "Authorization") == "Bearer cleanup-token")
  }

  @Test("transport cancellation remains structured cancellation")
  func cancellationMapping() throws {
    #expect(ApiClient.normalizeTransportError(CancellationError()) is CancellationError)
    #expect(ApiClient.normalizeTransportError(URLError(.cancelled)) is CancellationError)

    let mapped = try #require(ApiClient.normalizeTransportError(URLError(.timedOut)) as? APIError)
    guard case .networkError = mapped else {
      Issue.record("Expected non-cancellation URL errors to retain APIError.networkError")
      return
    }
  }

  @Test("cancelling a suspended URLSession request exits as cancellation")
  func suspendedRequestCancellation() async throws {
    await SuspendedRequestProbe.shared.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SuspendedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = ApiClient(
      urlSession: session,
      auth: Auth.mocked(authenticated: false).handle
    )

    let requestTask = Task {
      try await client.checkInviteCode("cancel-sentinel")
    }
    #expect(await SuspendedRequestProbe.shared.waitForStart())
    requestTask.cancel()

    do {
      _ = try await requestTask.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {
      // All transport cancellation representations share one caller contract.
    } catch {
      Issue.record("Expected CancellationError, got \(error)")
    }
    #expect(await SuspendedRequestProbe.shared.waitForStop())
  }
}

private actor SuccessfulRequestProbe {
  static let shared = SuccessfulRequestProbe()

  private var request: URLRequest?

  func reset() {
    request = nil
  }

  func record(_ request: URLRequest) {
    self.request = request
  }

  func capturedRequest() -> URLRequest? {
    request
  }
}

private final class SuccessfulURLProtocol: URLProtocol, @unchecked Sendable {
  override static func canInit(with _: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let capturedRequest = request
    Task {
      await SuccessfulRequestProbe.shared.record(capturedRequest)
      guard let url = capturedRequest.url,
            let response = HTTPURLResponse(
              url: url,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
            )
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }

      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"result":{"valid":true}}"#.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

private actor SuspendedRequestProbe {
  static let shared = SuspendedRequestProbe()

  private var started = false
  private var stopped = false

  func reset() {
    started = false
    stopped = false
  }

  func markStarted() {
    started = true
  }

  func markStopped() {
    stopped = true
  }

  func waitForStart() async -> Bool {
    await waitUntil { started }
  }

  func waitForStop() async -> Bool {
    await waitUntil { stopped }
  }

  private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private final class SuspendedURLProtocol: URLProtocol, @unchecked Sendable {
  override static func canInit(with _: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Task { await SuspendedRequestProbe.shared.markStarted() }
  }

  override func stopLoading() {
    Task { await SuspendedRequestProbe.shared.markStopped() }
  }
}
