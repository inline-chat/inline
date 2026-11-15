import CryptoKit
import Foundation
import InlineProtocol
import RealtimeV2
import Testing
@testable import InlineKit

/// Serves byte ranges of one body per host. Paths listed in `rejected` answer 403.
final class RangeCDN: URLProtocol, @unchecked Sendable {
  struct Host {
    var body: Data
    var rejected: Set<String> = []
    var ignoresRange = false
    var requests: [(path: String, range: String?)] = []
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var hosts: [String: Host] = [:]

  static func install(_ host: String, _ value: Host) { lock.withLock { hosts[host] = value } }
  static func requests(_ host: String) -> [(path: String, range: String?)] { lock.withLock { hosts[host]?.requests ?? [] } }

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
    let host = Self.lock.withLock { () -> Host? in
      Self.hosts[url.host!]?.requests.append((url.path, range))
      return Self.hosts[url.host!]
    }
    guard let host else { fail(404); return }
    if host.rejected.contains(url.path) { fail(403); return }
    let body = host.body
    if !host.ignoresRange, let range, let bounds = Self.bounds(range, count: body.count) {
      let slice = body.subdata(in: Int(bounds.lowerBound) ..< Int(bounds.upperBound) + 1)
      respond(206, ["Content-Range": "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(body.count)"], slice)
    } else {
      respond(200, [:], body)
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
