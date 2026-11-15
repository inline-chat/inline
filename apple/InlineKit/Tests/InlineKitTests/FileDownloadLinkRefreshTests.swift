import Auth
import Foundation
import Testing
@testable import InlineKit

@Suite("CDN link refresh", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct FileDownloadLinkRefreshTests {
  nonisolated private static let rejected = "https://cdn.test/doc"
  nonisolated private static let expired = "https://cdn.test/doc?exp=1000"
  nonisolated private static let fresh = "https://cdn.test/doc?exp=4102444800"

  @Test func rejectedLinkIsRefreshedOnceAndRetried() async throws {
    StubCDN.reset([Self.rejected: 403, Self.fresh: 200])
    let result = try await download(url: Self.rejected) { _ in URL(string: Self.fresh) }
    #expect(try result.get().lastPathComponent.hasPrefix("refresh-"))
    #expect(StubCDN.requested == [Self.rejected, Self.fresh])
  }

  @Test func rejectedLinkWithoutFresherOneFails() async throws {
    StubCDN.reset([Self.rejected: 403])
    let result = try await download(url: Self.rejected) { _ in nil }
    guard case let .failure(error) = result,
          case .httpStatus(403)? = error as? FileDownloadValidationError
    else {
      Issue.record("expected HTTP 403, got \(result)")
      return
    }
    #expect(StubCDN.requested == [Self.rejected])
  }

  @Test func expiredLinkIsRefreshedBeforeTheRequest() async throws {
    StubCDN.reset([Self.expired: 403, Self.fresh: 200])
    let result = try await download(url: Self.expired) { _ in URL(string: Self.fresh) }
    _ = try result.get()
    #expect(StubCDN.requested == [Self.fresh])
  }

  private func download(
    url: String,
    refresh: @escaping FileDownloader.CDNLinkRefresh
  ) async throws -> Result<URL, Error> {
    let owner = FileDownloader(
      auth: Auth.mocked(authenticated: true).handle,
      nativeCacheDirectories: [],
      urlProtocolClasses: [StubCDN.self]
    )
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("refresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: destination) }
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Error>, Never>) in
      owner.downloadFile(id: "doc_\(Int.random(in: 1 ... 1_000_000))", url: URL(string: url), localUrl: destination,
                         refreshLink: refresh) { _, result in
        continuation.resume(returning: result)
      }
    }
    await owner.resetSession()
    return result
  }
}

/// Answers each URL with a fixed status; 200 carries a small body.
final class StubCDN: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var statuses: [String: Int] = [:]
  nonisolated(unsafe) private static var log: [String] = []

  static func reset(_ statuses: [String: Int]) {
    lock.withLock {
      self.statuses = statuses
      log = []
    }
  }

  static var requested: [String] { lock.withLock { log } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let status = Self.lock.withLock {
      Self.log.append(url.absoluteString)
      return Self.statuses[url.absoluteString] ?? 500
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: status == 200 ? Data([1, 2, 3]) : Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
