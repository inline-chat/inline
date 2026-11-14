import Foundation
import GRDB
import Testing
@testable import InlineKit

@Suite("Photo download retries and link refresh", .timeLimit(.minutes(1)))
struct FileCachePhotoRetryTests {
  private static let oldURL = "https://cdn.example.com/p.jpg?exp=1000"
  private static let newURL = "https://cdn.example.com/p.jpg?exp=4102444800"

  @Test("a rejected link is refreshed through its message once, then the fresh link downloads")
  func refreshesRejectedLink() async throws {
    let database = try makeDatabase(url: Self.oldURL)
    let loader = Loader(responses: [Self.oldURL: .status(403), Self.newURL: .data])
    let refresher = MediaLinkRefresher(minimumInterval: 0) { _, _ in
      try await database.dbWriter.write { db in
        try db.execute(sql: "UPDATE photoSize SET cdnUrl = ?", arguments: [Self.newURL])
      }
    }
    let cache = FileCache(database: database, linkRefresher: refresher) { try await loader.load($0) }

    let url = await cache.downloadAndWait(photo: photo(Self.oldURL), reloadMessageOnFinish: message())
    defer { if let url { try? FileManager.default.removeItem(at: url) } }

    #expect(url != nil)
    // The expired link is refreshed before any request is spent on it.
    #expect(await loader.requested == [Self.newURL])
  }

  @Test("a rejected link with no fresher one stops after one request and cools down")
  func rejectedWithoutFresherLinkStops() async throws {
    let unexpiring = "https://cdn.example.com/p.jpg"
    let database = try makeDatabase(url: unexpiring)
    let loader = Loader(responses: [unexpiring: .status(403)])
    let refresher = MediaLinkRefresher(minimumInterval: 0) { _, _ in }
    let cache = FileCache(database: database, linkRefresher: refresher) { try await loader.load($0) }

    #expect(await cache.downloadAndWait(photo: photo(unexpiring), reloadMessageOnFinish: message()) == nil)
    #expect(await loader.requested == [unexpiring])

    // A view reappearing right away must not restart the cycle.
    #expect(await cache.downloadAndWait(photo: photo(unexpiring), reloadMessageOnFinish: message()) == nil)
    #expect(await loader.requested == [unexpiring])
  }

  @Test("404 is final after one request")
  func notFoundStops() async throws {
    let unexpiring = "https://cdn.example.com/gone.jpg"
    let database = try makeDatabase(url: unexpiring)
    let loader = Loader(responses: [unexpiring: .status(404)])
    let cache = FileCache(database: database, linkRefresher: MediaLinkRefresher { _, _ in }) {
      try await loader.load($0)
    }
    #expect(await cache.downloadAndWait(photo: photo(unexpiring)) == nil)
    #expect(await loader.requested.count == 1)
  }

  @Test("server errors retry a bounded number of times, honoring Retry-After")
  func transientErrorsAreBounded() async throws {
    let unexpiring = "https://cdn.example.com/busy.jpg"
    let database = try makeDatabase(url: unexpiring)
    let loader = Loader(responses: [unexpiring: .status(503, retryAfter: "0")])
    let cache = FileCache(database: database, linkRefresher: MediaLinkRefresher { _, _ in }) {
      try await loader.load($0)
    }
    #expect(await cache.downloadAndWait(photo: photo(unexpiring)) == nil)
    #expect(await loader.requested.count == FileCache.maxTransientAttempts)
  }

  @Test("a re-signed link replaces a running transfer only when it expires later")
  func replaceOnlyWithFresherLink() {
    func key(_ url: String, size: String = "f") -> PhotoDownloadSourceKey {
      PhotoDownloadSourceKey(photoID: 71, sizeType: size, format: .jpeg, cdnURL: url)
    }
    #expect(FileCache.shouldReplace(running: key(Self.oldURL), with: key(Self.newURL)))
    #expect(!FileCache.shouldReplace(running: key(Self.newURL), with: key(Self.oldURL)))
    #expect(FileCache.shouldReplace(running: key(Self.newURL), with: key(Self.oldURL, size: "y")))
    // Links without an expiry keep newest-wins.
    #expect(FileCache.shouldReplace(running: key("https://a/1.jpg"), with: key("https://a/2.jpg")))
  }

  // MARK: - Helpers

  private func photo(_ url: String) -> PhotoInfo {
    PhotoInfo(photo: Photo(id: 9, photoId: 71, format: .jpeg), sizes: [
      PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: url),
    ])
  }

  private func message() -> Message {
    var message = Message.preview
    message.photoId = 71
    return message
  }

  private func makeDatabase(url: String) throws -> AppDatabase {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    try queue.write { db in
      try Photo(id: 9, photoId: 71, format: .jpeg).insert(db)
      try PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: url).insert(db)
    }
    return database
  }

  private actor Loader {
    enum Response {
      case data
      case status(Int, retryAfter: String? = nil)
    }

    private let responses: [String: Response]
    private(set) var requested: [String] = []

    init(responses: [String: Response]) {
      self.responses = responses
    }

    func load(_ url: URL) throws -> (Data, URLResponse) {
      requested.append(url.absoluteString)
      switch responses[url.absoluteString] ?? .status(500) {
        case .data:
          return (Data([0xFF, 0xD8, 0xFF]), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case let .status(code, retryAfter):
          let headers = retryAfter.map { ["Retry-After": $0] }
          return (Data(), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!)
      }
    }
  }
}

@Suite("Media link expiry and refresh")
struct MediaLinkRefresherTests {
  @Test("reads proxy and R2 expiries")
  func parsesExpiry() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    #expect(MediaLinkExpiry.isExpired(URL(string: "https://api/file?id=a&exp=1999999000&sig=x"), now: now))
    #expect(!MediaLinkExpiry.isExpired(URL(string: "https://api/file?id=a&exp=2000999000&sig=x"), now: now))
    let r2 = "https://r2/obj?X-Amz-Date=20330518T033320Z&X-Amz-Expires=604800&X-Amz-Signature=s"
    #expect(MediaLinkExpiry.expiryDate(URL(string: r2)) == Date(timeIntervalSince1970: 2_000_000_000 + 604_800))
    #expect(MediaLinkExpiry.expiryDate(URL(string: "https://r2/obj")) == nil)
    #expect(!MediaLinkExpiry.isExpired(URL(fileURLWithPath: "/tmp/a.jpg"), now: now))
  }

  @Test("concurrent refreshes share one fetch and repeats wait for the interval")
  func dedupesAndThrottles() async {
    let counter = Counter()
    let refresher = MediaLinkRefresher(minimumInterval: 60) { _, _ in
      await counter.increment()
      try await Task.sleep(for: .milliseconds(50))
    }
    async let first = refresher.refresh(peer: .user(id: 2), messageId: 5)
    async let second = refresher.refresh(peer: .user(id: 2), messageId: 5)
    let results = await [first, second]
    #expect(results == [true, true])
    #expect(await counter.value == 1)

    #expect(await refresher.refresh(peer: .user(id: 2), messageId: 5) == false)
    #expect(await counter.value == 1)
    #expect(await refresher.refresh(peer: .user(id: 2), messageId: 0) == false)
  }

  private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
  }
}
