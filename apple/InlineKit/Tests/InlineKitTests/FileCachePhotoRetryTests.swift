import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
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

  @Test("a throttled refresh still uses a newer link that a recent fetch stored")
  func throttledRefreshUsesStoredLink() async throws {
    let photoID: Int64 = 7_201
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    // The stored row already has the re-signed link; the view still holds the expired one.
    try await queue.write { db in
      try Photo(id: 9, photoId: photoID, format: .jpeg).insert(db)
      try PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: Self.newURL).insert(db)
    }
    let stale = PhotoInfo(photo: Photo(id: 9, photoId: photoID, format: .jpeg), sizes: [
      PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: Self.oldURL),
    ])
    var reload = message()
    reload.photoId = photoID
    let loader = Loader(responses: [Self.newURL: .data])
    let fetches = LinkFetchCounter()
    let refresher = MediaLinkRefresher(minimumInterval: 60) { _, _ in await fetches.increment() }
    // That fetch ran a moment ago, so this download's refresh is throttled.
    #expect(await refresher.refresh(peer: reload.peerId, messageId: reload.messageId))
    let cache = FileCache(database: database, linkRefresher: refresher) { try await loader.load($0) }

    let url = await cache.downloadAndWait(photo: stale, reloadMessageOnFinish: reload)
    defer { if let url { try? FileManager.default.removeItem(at: url) } }

    #expect(url != nil)
    #expect(await loader.requested == [Self.newURL])
    #expect(await fetches.value == 1)
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

  // MARK: - Native photos

  private static let unexpiring = "https://cdn.example.com/native.jpg"

  // Each native test uses its own photo id: the cache file is named after it, in a folder
  // that tests running in parallel share.
  private func nativeDatabase(fileID: String?, photoID: Int64) throws -> AppDatabase {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    try queue.write { db in
      try Photo(id: 9, photoId: photoID, format: .jpeg).insert(db)
      try PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: Self.unexpiring, fileUniqueId: fileID).insert(db)
    }
    return database
  }

  private func nativePhoto(fileID: String?, photoID: Int64) -> PhotoInfo {
    PhotoInfo(photo: Photo(id: 9, photoId: photoID, format: .jpeg), sizes: [
      PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: Self.unexpiring, fileUniqueId: fileID),
    ])
  }

  private func sentMessage(photoID: Int64) -> InlineKit.Message {
    var message = message()
    message.photoId = photoID
    message.messageId = 44
    message.chatId = 5
    return message
  }

  @Test("a stored photo identity downloads natively by its message, with no CDN request")
  func nativePhotoSkipsCDN() async throws {
    let database = try nativeDatabase(fileID: "INP_photo", photoID: 7_171)
    let loader = Loader(responses: [:])
    let native = NativePhotoProbe(result: .data(Data([0xFF, 0xD8, 0xFF, 0xE0])))
    let cache = FileCache(database: database, linkRefresher: MediaLinkRefresher { _, _ in },
      photoDataLoader: { try await loader.load($0) }, nativePhotoLoader: { try await native.load($0, $1, $2) })
    let url = await cache.downloadAndWait(photo: nativePhoto(fileID: "INP_photo", photoID: 7_171),
      reloadMessageOnFinish: sentMessage(photoID: 7_171))
    defer { if let url { try? FileManager.default.removeItem(at: url) } }
    let stored = try #require(url)
    #expect(try Data(contentsOf: stored) == Data([0xFF, 0xD8, 0xFF, 0xE0]))
    #expect(await loader.requested.isEmpty)
    let calls = await native.calls
    #expect(calls.count == 1 && calls.first?.fileID == "INP_photo")
    #expect(calls.first?.chatID == 5 && calls.first?.messageID == 44)
    let localPath = try await database.dbWriter.read { db in try PhotoSize.fetchOne(db)?.localPath }
    #expect(localPath != nil)
  }

  @Test("any native failure, a refusal included, falls back to the photo's signed CDN link")
  func nativePhotoFailures() async throws {
    let refusal = RealtimeDirectRpcError.rpcError(errorCode: .badRequest, message: "Bad request", code: 400)
    for (failure, photoID) in [(NativePhotoProbe.Result.fail(refusal), Int64(7_181)),
                               (.fail(RealtimeDirectRpcError.timeout), 7_182)] {
      let database = try nativeDatabase(fileID: "INP_photo", photoID: photoID)
      let loader = Loader(responses: [Self.unexpiring: .data])
      let native = NativePhotoProbe(result: failure)
      let cache = FileCache(database: database, linkRefresher: MediaLinkRefresher { _, _ in },
        photoDataLoader: { try await loader.load($0) }, nativePhotoLoader: { try await native.load($0, $1, $2) })
      let url = await cache.downloadAndWait(photo: nativePhoto(fileID: "INP_photo", photoID: photoID),
        reloadMessageOnFinish: sentMessage(photoID: photoID))
      defer { if let url { try? FileManager.default.removeItem(at: url) } }
      #expect(url != nil)
      #expect(await loader.requested == [Self.unexpiring])
      #expect(await native.calls.count == 1)
    }
  }

  @Test("without a stored identity, the photo's own message, or native enabled, the photo uses the CDN")
  func nativePhotoNeedsIdentityAndMessage() async throws {
    // The last case is a reply preview: the parent message, which does not own this photo.
    for (photoID, fileID, sendsMessage, native) in [(Int64(7_191), nil as String?, true, NativePhotoProbe.Result.data(Data([1]))),
                                                    (7_192, "INP_photo", false, .data(Data([1]))),
                                                    (7_193, "INP_photo", true, .disabled),
                                                    (7_195, "INP_photo", true, .data(Data([1])))] {
      var message = sendsMessage ? sentMessage(photoID: photoID) : nil
      if photoID == 7_195 { message?.photoId = 99 }
      let database = try nativeDatabase(fileID: fileID, photoID: photoID)
      let loader = Loader(responses: [Self.unexpiring: .data])
      let probe = NativePhotoProbe(result: native)
      let cache = FileCache(database: database, linkRefresher: MediaLinkRefresher { _, _ in },
        photoDataLoader: { try await loader.load($0) }, nativePhotoLoader: { try await probe.load($0, $1, $2) })
      let url = await cache.downloadAndWait(photo: nativePhoto(fileID: fileID, photoID: photoID), reloadMessageOnFinish: message)
      defer { if let url { try? FileManager.default.removeItem(at: url) } }
      #expect(url != nil)
      #expect(await loader.requested == [Self.unexpiring])
    }
  }

  @Test("photo sizes keep the server identity from the wire, and an update without one keeps it")
  func photoSizeIdentityFromProtocol() throws {
    var proto = InlineProtocol.PhotoSize()
    proto.type = "f"
    proto.w = 10
    proto.h = 10
    proto.fileUniqueID = "INP_wire"
    #expect(PhotoSize.from(proto: proto, photoId: 1).fileUniqueId == "INP_wire")
    proto.clearFileUniqueID()
    #expect(PhotoSize.from(proto: proto, photoId: 1).fileUniqueId == nil)

    let database = try nativeDatabase(fileID: "INP_stored", photoID: 7_194)
    try database.dbWriter.write { db in
      try PhotoSize.updateFromProtocol(db, protoSize: proto, photoId: 9)
    }
    #expect(try database.dbWriter.read { db in try PhotoSize.fetchOne(db)?.fileUniqueId } == "INP_stored")
  }

  // MARK: - Helpers

  private func photo(_ url: String) -> PhotoInfo {
    PhotoInfo(photo: Photo(id: 9, photoId: 71, format: .jpeg), sizes: [
      PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: url),
    ])
  }

  private func message() -> InlineKit.Message {
    var message = InlineKit.Message.preview
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

private actor LinkFetchCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// Stands in for the native photo download: writes the given bytes or fails.
private actor NativePhotoProbe {
  enum Result: Sendable {
    case data(Data)
    case fail(any Error & Sendable)
    case disabled
  }

  struct Call: Sendable {
    let fileID: String
    let chatID: Int64
    let messageID: Int64
  }

  private let result: Result
  private(set) var calls: [Call] = []

  init(result: Result) { self.result = result }

  func load(_ fileID: String, _ location: FileMessageLocation, _ destination: URL) throws -> URL? {
    calls.append(Call(fileID: fileID, chatID: location.chatID, messageID: location.messageID))
    switch result {
    case let .data(data):
      try data.write(to: destination)
      return destination
    case let .fail(error):
      throw error
    case .disabled:
      return nil
    }
  }
}
