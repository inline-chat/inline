import CryptoKit
import Foundation
import InlineProtocol
import RealtimeV2
import Testing
@testable import InlineKit

/// Serves byte ranges of one body per host. Paths listed in `rejected` answer 403. With an
/// `etag`, a range whose `If-Range` names another one gets the whole body, as the media proxy does.
final class RangeCDN: URLProtocol, @unchecked Sendable {
  struct Host {
    var body: Data
    var rejected: Set<String> = []
    var ignoresRange = false
    var contentType: String?
    var etag: String?
    var requests: [(path: String, range: String?, ifRange: String?)] = []
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var hosts: [String: Host] = [:]

  static func install(_ host: String, _ value: Host) { lock.withLock { hosts[host] = value } }
  static func update(_ host: String, _ change: (inout Host) -> Void) { lock.withLock { change(&hosts[host]!) } }
  static func requests(_ host: String) -> [(path: String, range: String?, ifRange: String?)] { lock.withLock { hosts[host]?.requests ?? [] } }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RangeCDN.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let range = request.value(forHTTPHeaderField: "Range")
    let ifRange = request.value(forHTTPHeaderField: "If-Range")
    let host = Self.lock.withLock { () -> Host? in
      Self.hosts[url.host!]?.requests.append((url.path, range, ifRange))
      return Self.hosts[url.host!]
    }
    guard let host else { fail(404); return }
    if host.rejected.contains(url.path) { fail(403); return }
    let body = host.body
    var headers: [String: String] = [:]
    if let contentType = host.contentType { headers["Content-Type"] = contentType }
    if let etag = host.etag { headers["ETag"] = etag }
    let honorsRange = !host.ignoresRange && (ifRange == nil || ifRange == host.etag)
    if honorsRange, let range, let bounds = Self.bounds(range, count: body.count) {
      let slice = body.subdata(in: Int(bounds.lowerBound) ..< Int(bounds.upperBound) + 1)
      headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(body.count)"
      respond(206, headers, slice)
    } else {
      respond(200, headers, body)
    }
  }

  override func stopLoading() {}

  private static func bounds(_ header: String, count: Int) -> ClosedRange<UInt64>? {
    let spec = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
    guard spec.count == 2, let start = UInt64(spec[0]), let end = UInt64(spec[1]), start < UInt64(count) else { return nil }
    return start ... min(end, UInt64(count) - 1)
  }

  private func fail(_ status: Int) { respond(status, [:], Data()) }

  private func respond(_ status: Int, _ headers: [String: String], _ body: Data) {
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
}

private func rangeInput(offset: UInt64, limit: UInt32 = 524_288) -> GetFilePartInput {
  var input = GetFilePartInput()
  input.fileUniqueID = "INP_cdn"
  input.offset = offset
  input.limit = limit
  return input
}

@Suite("CDN range source")
struct CDNRangeSourceTests {
  @Test func parsesContentRangeAndRejectsUnusableOnes() {
    #expect(CDNRangeSource.parseContentRange("bytes 0-9/100")! == (0, 9, 100))
    #expect(CDNRangeSource.parseContentRange("bytes 524288-1048575/2000000")! == (524_288, 1_048_575, 2_000_000))
    #expect(CDNRangeSource.parseContentRange("bytes 0-9/*") == nil)
    #expect(CDNRangeSource.parseContentRange("bytes 9-0/100") == nil)
    #expect(CDNRangeSource.parseContentRange("bytes 0-100/100") == nil)
    #expect(CDNRangeSource.parseContentRange("items 0-9/100") == nil)
  }

  @Test func acceptsOnlyTheRangeThatWasAskedFor() throws {
    let body = Data(repeating: 5, count: 10)
    let part = try CDNRangeSource.part(for: rangeInput(offset: 0, limit: 10), status: 206, contentRange: "bytes 0-9/30", data: body)
    #expect(part.offset == 0 && part.totalSize == 30 && part.data == body)
    #expect(part.sha256 == Data(SHA256.hash(data: body)))
    #expect(throws: CDNRangeError.rangeNotSupported) {
      try CDNRangeSource.part(for: rangeInput(offset: 10, limit: 10), status: 206, contentRange: "bytes 0-9/30", data: body)
    }
    #expect(throws: CDNRangeError.rangeNotSupported) {
      try CDNRangeSource.part(for: rangeInput(offset: 0, limit: 10), status: 206, contentRange: "bytes 0-9/30", data: body.prefix(9))
    }
    // A whole-file 200 is the range only when the file fits in it.
    #expect(try CDNRangeSource.part(for: rangeInput(offset: 0, limit: 10), status: 200, contentRange: nil, data: body).totalSize == 10)
    #expect(throws: CDNRangeError.rangeNotSupported) {
      try CDNRangeSource.part(for: rangeInput(offset: 0, limit: 4), status: 200, contentRange: nil, data: body)
    }
    #expect(throws: CDNRangeError.rangeNotSupported) {
      try CDNRangeSource.part(for: rangeInput(offset: 4, limit: 4), status: 200, contentRange: nil, data: body)
    }
    // With the file's size known, a whole body of another size is something else.
    #expect(try CDNRangeSource.part(for: rangeInput(offset: 0, limit: 10), status: 200, contentRange: nil, data: body, expectedTotal: 10).totalSize == 10)
    #expect(throws: CDNRangeError.notTheFile) {
      try CDNRangeSource.part(for: rangeInput(offset: 0, limit: 10), status: 200, contentRange: nil, data: body, expectedTotal: 30)
    }
    #expect(throws: CDNRangeError.httpStatus(503)) {
      try CDNRangeSource.part(for: rangeInput(offset: 0), status: 503, contentRange: nil, data: Data())
    }
    #expect(CDNRangeError.httpStatus(503).isTransient && CDNRangeError.httpStatus(429).isTransient)
    #expect(!CDNRangeError.httpStatus(404).isTransient && !CDNRangeError.rangeNotSupported.isTransient)
  }

  @Test func requestsExactRangesOverHTTP() async throws {
    let body = Data((0 ..< 524_288 + 100).map { UInt8($0 % 253) })
    RangeCDN.install("ranges.test", .init(body: body))
    let source = CDNRangeSource(link: CDNLink(URL(string: "https://ranges.test/file")!, refresh: nil), session: RangeCDN.session())
    let tail = try await source.fetchFilePart(rangeInput(offset: 524_288), timeout: .seconds(10))
    #expect(tail.offset == 524_288 && tail.totalSize == UInt64(body.count))
    #expect(tail.data == body.suffix(100))
    #expect(RangeCDN.requests("ranges.test").map(\.range) == ["bytes=524288-1048575"])
  }

  @Test func rejectedLinkRefreshesOnceForConcurrentRanges() async throws {
    let body = Data(repeating: 7, count: 524_288 * 2)
    RangeCDN.install("refresh.test", .init(body: body, rejected: ["/stale"]))
    let refreshes = RefreshCounter()
    let link = CDNLink(URL(string: "https://refresh.test/stale")!) { _ in
      await refreshes.increment()
      return URL(string: "https://refresh.test/fresh")!
    }
    let source = CDNRangeSource(link: link, session: RangeCDN.session())
    async let first = source.fetchFilePart(rangeInput(offset: 0), timeout: .seconds(10))
    async let second = source.fetchFilePart(rangeInput(offset: 524_288), timeout: .seconds(10))
    let parts = try await [first, second]
    #expect(parts.map(\.data) == [body.prefix(524_288), body.suffix(524_288)])
    #expect(await refreshes.value == 1)
    #expect(await link.current().path == "/fresh")
  }

  @Test func aWebPageInPlaceOfTheFileIsRejected() async throws {
    let body = Data("<html>Sign in to the Wi-Fi</html>".utf8)
    RangeCDN.install("portal.test", .init(body: body, ignoresRange: true, contentType: "text/html; charset=utf-8"))
    let link = CDNLink(URL(string: "https://portal.test/file")!, refresh: nil)
    await #expect(throws: CDNRangeError.notTheFile) {
      try await CDNRangeSource(link: link, session: RangeCDN.session()).fetchFilePart(rangeInput(offset: 0), timeout: .seconds(10))
    }
    // A file that is itself a web page may come back as one.
    let page = try await CDNRangeSource(link: link, session: RangeCDN.session(), acceptsHTML: true)
      .fetchFilePart(rangeInput(offset: 0), timeout: .seconds(10))
    #expect(page.data == body)
  }

  @Test func aWholeSmallBodyIsTheFileWhateverSizeItsMessageClaims() async throws {
    // Legacy metadata can be wrong; a server that ignores Range sends the whole small file.
    let body = Data(repeating: 4, count: 100)
    RangeCDN.install("whole.test", .init(body: body, ignoresRange: true))
    let link = CDNLink(URL(string: "https://whole.test/file")!, refresh: nil)
    let part = try await CDNRangeSource(link: link, session: RangeCDN.session()).fetchFilePart(rangeInput(offset: 0), timeout: .seconds(10))
    #expect(part.data == body && part.totalSize == 100)
  }

  @Test func laterRangesNameTheFirstRangesObjectAndAChangedObjectStops() async throws {
    let body = Data((0 ..< 524_288 * 3).map { UInt8($0 % 239) })
    RangeCDN.install("changed.test", .init(body: body, etag: "\"v1\""))
    let source = CDNRangeSource(link: CDNLink(URL(string: "https://changed.test/file")!, refresh: nil), session: RangeCDN.session())
    _ = try await source.fetchFilePart(rangeInput(offset: 0), timeout: .seconds(10))
    let second = try await source.fetchFilePart(rangeInput(offset: 524_288), timeout: .seconds(10))
    #expect(second.data == body.subdata(in: 524_288 ..< 1_048_576))
    #expect(RangeCDN.requests("changed.test").map(\.ifRange) == [nil, "\"v1\""])
    // The object is replaced: its server answers the stale If-Range with all of the new one.
    RangeCDN.update("changed.test") { $0.etag = "\"v2\""; $0.body = Data(repeating: 1, count: body.count) }
    await #expect(throws: CDNRangeError.objectChanged) {
      try await source.fetchFilePart(rangeInput(offset: 1_048_576), timeout: .seconds(10))
    }
    // A weak ETag may not be used in If-Range; Last-Modified stands in.
    let weak = HTTPURLResponse(url: URL(string: "https://changed.test/file")!, statusCode: 206, httpVersion: nil,
      headerFields: ["ETag": "W/\"v1\"", "Last-Modified": "Wed, 18 Nov 2026 10:00:00 GMT"])!
    #expect(CDNRangeSource.validator(weak) == "Wed, 18 Nov 2026 10:00:00 GMT")
  }

  @Test func linkStillRejectedAfterRefreshIsTerminal() async throws {
    RangeCDN.install("dead.test", .init(body: Data([1]), rejected: ["/stale", "/also-stale"]))
    let link = CDNLink(URL(string: "https://dead.test/stale")!) { _ in URL(string: "https://dead.test/also-stale")! }
    let source = CDNRangeSource(link: link, session: RangeCDN.session())
    await #expect(throws: CDNRangeError.linkRejected(403)) {
      try await source.fetchFilePart(rangeInput(offset: 0), timeout: .seconds(10))
    }
  }
}

private actor RefreshCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

/// Serves parts of `body`, failing every request for `failingOffset` with `failure`.
private struct FlakyNative: NativeFilePartFetching {
  let body: Data
  let failingOffset: UInt64
  let failure: any Error & Sendable

  func fetchFilePart(_ input: GetFilePartInput, timeout _: Duration) async throws -> GetFilePartResult {
    if input.offset == failingOffset { throw failure }
    var part = GetFilePartResult()
    part.offset = input.offset
    part.totalSize = UInt64(body.count)
    part.data = body.subdata(in: Int(input.offset) ..< min(body.count, Int(input.offset) + Int(input.limit)))
    part.sha256 = Data(SHA256.hash(data: part.data))
    return part
  }
}

@Suite("Native download with CDN range fallback")
struct NativeRangeFallbackTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("range-fallback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func run(
    host: String, native: FlakyNative, in directory: URL
  ) async throws -> NativeDownloadOutcome {
    let link = CDNLink(URL(string: "https://\(host)/file")!, refresh: nil)
    let session = RangeCDN.session()
    let destination = directory.appendingPathComponent("finished")
    return try await NativeMessageFileDownload.downloadWithRangeFallback(
      manager: NativeDownloadManager(retryBaseDelay: .milliseconds(20)), native: native, link: link, progress: { _, _ in },
      validateAccount: {}
    ) { transport, stallBudget in
      // The production budget is 30 s; a short one keeps the test fast.
      let source: any NativeFilePartFetching = (transport as? CDNRangeSource).map { CDNRangeSource(link: $0.link, session: session) } ?? transport
      return .init(accountID: 1, fileUniqueID: "INP_fallback", destination: destination,
        stallBudget: stallBudget.map { _ in .milliseconds(300) }, transport: source)
    }
  }

  @Test func cdnFinishesTheSamePartialWithOnlyTheMissingRange() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let body = Data((0 ..< 524_288 * 3).map { UInt8($0 % 241) })
    RangeCDN.install("fallback.test", .init(body: body))
    let native = FlakyNative(body: body, failingOffset: 524_288, failure: RealtimeDirectRpcError.timeout)
    let outcome = try await run(host: "fallback.test", native: native, in: folder)
    #expect(try Data(contentsOf: outcome.file) == body)
    #expect(outcome.fallback is RealtimeDirectRpcError)
    #expect(RangeCDN.requests("fallback.test").map(\.range) == ["bytes=524288-1048575"])
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("INP_fallback.inline-partial").path))
  }

  @Test(arguments: [400, 404])
  func missingOrLegacyNativeFileFallsBackToTheCDN(status: Int) async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let body = Data((0 ..< 524_288 * 2).map { UInt8($0 % 233) })
    let host = "legacy\(status).test"
    RangeCDN.install(host, .init(body: body))
    // The server answers a legacy file it has no size or path for like an inaccessible one.
    let refusal = RealtimeDirectRpcError.rpcError(errorCode: .badRequest, message: "Bad request", code: status)
    let native = FlakyNative(body: body, failingOffset: 0, failure: refusal)
    let outcome = try await run(host: host, native: native, in: folder)
    #expect(try Data(contentsOf: outcome.file) == body)
    #expect(outcome.fallback is RealtimeDirectRpcError)
    #expect(Set(RangeCDN.requests(host).compactMap(\.range)) == ["bytes=0-524287", "bytes=524288-1048575"])
  }

  @Test func permissionFailureNeverFallsBack() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let body = Data(repeating: 2, count: 524_288 * 2)
    RangeCDN.install("denied.test", .init(body: body))
    let native = FlakyNative(body: body, failingOffset: 524_288, failure: RealtimeDirectRpcError.notAuthorized)
    await #expect(throws: RealtimeDirectRpcError.self) { try await run(host: "denied.test", native: native, in: folder) }
    #expect(RangeCDN.requests("denied.test").isEmpty)
  }

  @Test func bothFailingKeepsVerifiedBytesAndReportsBoth() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let body = Data(repeating: 3, count: 524_288 * 2)
    // No body for this host: every range answers 404.
    let native = FlakyNative(body: body, failingOffset: 524_288, failure: RealtimeDirectRpcError.notConnected)
    do {
      _ = try await run(host: "missing.test", native: native, in: folder)
      Issue.record("expected a failure")
    } catch let failure as NativeRangeFallbackFailure {
      #expect(failure.native is RealtimeDirectRpcError)
      #expect(failure.cdn as? CDNRangeError == .httpStatus(404))
    }
    let partial = folder.appendingPathComponent("INP_fallback.inline-partial")
    #expect(try Data(contentsOf: partial).prefix(524_288) == body.prefix(524_288))
  }
}
