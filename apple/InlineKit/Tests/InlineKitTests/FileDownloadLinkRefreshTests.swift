import Auth
import Foundation
import GRDB
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

  @Test func throttledRefreshStillUsesANewerStoredLink() async throws {
    let database = try AppDatabase(DatabaseQueue())
    let fetches = LinkFetchCounter()
    let refresher = MediaLinkRefresher(minimumInterval: 60) { _, _ in await fetches.increment() }
    // A fetch a moment ago, for another view of this message, stored a re-signed link.
    #expect(await refresher.refresh(peer: .user(id: 2), messageId: 5))
    func refresh(storing link: String) -> FileDownloader.CDNLinkRefresh {
      FileDownloader.linkRefresh(peer: .user(id: 2), messageId: 5, refresher: refresher, database: database) { db in
        try String.fetchOne(db, sql: "SELECT ?", arguments: [link])
      }
    }
    let stale = try #require(URL(string: Self.rejected))
    #expect(await refresh(storing: Self.fresh)(stale) == URL(string: Self.fresh))
    // A stored link that expired, or is the stale one, is not worth a request.
    #expect(await refresh(storing: Self.expired)(stale) == nil)
    #expect(await refresh(storing: Self.rejected)(stale) == nil)
    #expect(await fetches.value == 1)
  }

  @Test func webPageInPlaceOfAFileFailsUnlessTheFileIsOne() async throws {
    StubCDN.reset([Self.fresh: 200], contentTypes: [Self.fresh: "text/html; charset=utf-8"])
    let result = try await download(url: Self.fresh) { _ in nil }
    guard case let .failure(error) = result,
          case .unexpectedContentType? = error as? FileDownloadValidationError
    else {
      Issue.record("expected a rejected web page, got \(result)")
      return
    }
    StubCDN.reset([Self.fresh: 200], contentTypes: [Self.fresh: "text/html"])
    _ = try await download(url: Self.fresh, pathExtension: "html") { _ in nil }.get()
  }

  private func download(
    url: String,
    pathExtension: String? = nil,
    refresh: @escaping FileDownloader.CDNLinkRefresh
  ) async throws -> Result<URL, Error> {
    let owner = FileDownloader(
      auth: Auth.mocked(authenticated: true).handle,
      nativeCacheDirectories: [],
      urlProtocolClasses: [StubCDN.self]
    )
    var destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("refresh-\(UUID().uuidString)")
    if let pathExtension { destination.appendPathExtension(pathExtension) }
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

private actor LinkFetchCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// Answers each URL with a fixed status and, if given, Content-Type; 200 carries a small body.
final class StubCDN: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var statuses: [String: Int] = [:]
  nonisolated(unsafe) private static var contentTypes: [String: String] = [:]
  nonisolated(unsafe) private static var log: [String] = []

  static func reset(_ statuses: [String: Int], contentTypes: [String: String] = [:]) {
    lock.withLock {
      self.statuses = statuses
      self.contentTypes = contentTypes
      log = []
    }
  }

  static var requested: [String] { lock.withLock { log } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let (status, contentType) = Self.lock.withLock {
      Self.log.append(url.absoluteString)
      return (Self.statuses[url.absoluteString] ?? 500, Self.contentTypes[url.absoluteString])
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: contentType.map { ["Content-Type": $0] })!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: status == 200 ? Data([1, 2, 3]) : Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
