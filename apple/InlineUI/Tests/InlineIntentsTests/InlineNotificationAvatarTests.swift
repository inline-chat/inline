import Foundation
import Testing
@testable import InlineIntents

@Suite("Bounded notification avatar download")
struct InlineNotificationAvatarTests {
  @Test func onlyConfirmedAbsenceOfPhotoAllowsInitials() {
    #expect(InlineNotificationAvatar.fallbackSource(hasProfilePhoto: false, hasPhotoURL: false) == .noPhotoConfigured)
    #expect(InlineNotificationAvatar.fallbackSource(hasProfilePhoto: nil, hasPhotoURL: false) == .configuredPhotoUnavailable)
    #expect(InlineNotificationAvatar.fallbackSource(hasProfilePhoto: true, hasPhotoURL: false) == .configuredPhotoUnavailable)
    #expect(InlineNotificationAvatar.fallbackSource(hasProfilePhoto: false, hasPhotoURL: true) == .configuredPhotoUnavailable)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["valid", "exact-limit", "oversize-header", "oversize-stream", "misleading-length", "not-found", "insecure"])
  func boundsResponseBeforeImageDecoding(scenario: String) async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AvatarProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let scheme = scenario == "insecure" ? "http" : "https"
    let url = URL(string: "\(scheme)://notification.invalid/\(scenario)")!
    let data = await InlineNotificationAvatar.data(from: url, session: session)
    switch scenario {
    case "valid": #expect(data == Data([1, 2, 3]))
    case "exact-limit": #expect(data?.count == InlineNotificationAvatar.maximumBytes)
    default: #expect(data == nil)
    }
    if ["oversize-header", "oversize-stream", "misleading-length"].contains(scenario) {
      await expectStopped(url)
    }
  }

  @Test(.timeLimit(.minutes(1))) func cancellationWhileWaitingForHeadersStopsTheRequest() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AvatarProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://notification.invalid/delayed-headers")!
    let task = Task { await InlineNotificationAvatar.data(from: url, session: session) }
    for _ in 0..<100 {
      if AvatarProtocol.events.contains("started", url: url) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(AvatarProtocol.events.contains("started", url: url))
    task.cancel()
    #expect(await task.value == nil)
    await expectStopped(url)
  }

  private func expectStopped(_ url: URL) async {
    for _ in 0..<100 {
      if AvatarProtocol.events.contains("stopped", url: url) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(AvatarProtocol.events.contains("stopped", url: url))
  }
}

private final class AvatarProtocol: URLProtocol, @unchecked Sendable {
  static let events = ProtocolEvents()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.events.record("started", url: request.url!)
    let path = request.url!.lastPathComponent
    if path == "delayed-headers" { return }
    let maximum = InlineNotificationAvatar.maximumBytes
    let headers: [String: String] = switch path {
    case "oversize-header": ["Content-Length": String(maximum + 1)]
    case "misleading-length": ["Content-Length": String(maximum)]
    default: [:]
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: path == "not-found" ? 404 : 200,
      httpVersion: "HTTP/1.1", headerFields: headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if path == "oversize-header" {
      // Never complete: rejecting the headers must return without waiting for a body.
      return
    }
    if ["oversize-stream", "exact-limit", "misleading-length"].contains(path) {
      for _ in 0..<32 { client?.urlProtocol(self, didLoad: Data(repeating: 1, count: maximum / 32)) }
      if path != "exact-limit" {
        client?.urlProtocol(self, didLoad: Data([1]))
        // Never complete: the reader must stop as soon as it crosses the byte budget.
        return
      }
    } else {
      client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() { Self.events.record("stopped", url: request.url!) }
}

private final class ProtocolEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: Set<String> = []
  func record(_ event: String, url: URL) { lock.withLock { _ = events.insert(event + url.absoluteString) } }
  func contains(_ event: String, url: URL) -> Bool { lock.withLock { events.contains(event + url.absoluteString) } }
}
