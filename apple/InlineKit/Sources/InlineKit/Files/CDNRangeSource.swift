import CryptoKit
import Foundation
import InlineCompat
import InlineProtocol

/// HTTP failures from the CDN range source, classified for the download engine's retry policy.
enum CDNRangeError: Error, Equatable, Sendable {
  /// The CDN answered with this status. 408, 429 and 5xx are transient.
  case httpStatus(Int)
  /// The CDN ignored or mangled the requested range.
  case rangeNotSupported
  /// The link was rejected, and a refreshed one was too or could not be had.
  case linkRejected(Int)
  /// The CDN answered with something that is not the file, such as a captive portal's page.
  case notTheFile
  /// The object changed after this transfer's first range, so its bytes cannot be combined.
  case objectChanged

  var isTransient: Bool {
    guard case let .httpStatus(status) = self else { return false }
    return status == 408 || status == 429 || (500 ... 599).contains(status)
  }
}

/// The current signed link for one file, refreshed at most once per rejection.
actor CDNLink {
  typealias Refresh = @Sendable (_ stale: URL) async -> URL?

  private var url: URL
  private let refresh: Refresh?
  private var refreshing: Task<URL?, Never>?

  init(_ url: URL, refresh: Refresh?) {
    self.url = url
    self.refresh = refresh
  }

  func current() -> URL { url }

  /// A link newer than `stale`, fetching one if no other request already has. Concurrent ranges
  /// rejected with the same link share one refresh.
  func renewed(after stale: URL) async -> URL? {
    if url != stale { return url }
    if let refreshing { return await refreshing.value }
    guard let refresh else { return nil }
    let task = Task { await refresh(stale) }
    refreshing = task
    let fresh = await task.value
    refreshing = nil
    if let fresh { url = fresh }
    return fresh
  }
}

/// Serves `getFilePart` ranges from the CDN with HTTP `Range` requests, so a download that falls
/// back from the native transport fills the same sparse partial instead of starting over.
/// The CDN sends no per-range digest: integrity rests on TLS and the exact byte count, as for
/// the whole-file CDN path. Later ranges carry `If-Range` with the first range's validator, so a
/// changed object answers with all of itself instead of a range of different bytes.
struct CDNRangeSource: NativeFilePartFetching {
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    // The download window can hold up to 12 ranges; let them all run.
    configuration.httpMaximumConnectionsPerHost = 12
    return URLSession(configuration: configuration)
  }()

  let link: CDNLink
  var session: URLSession = Self.session
  /// Whether the file may itself be a web page. Otherwise an HTML answer is a captive portal or
  /// an error page standing in for it.
  var acceptsHTML = false
  /// What the first range said about the object, shared by this transfer's ranges.
  let object = CDNRangeObject()

  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    guard input.limit > 0 else { throw NativeFileDownloadError.invalidRequest }
    var url = await link.current()
    let known = object.current()
    for attempt in 0 ... 1 {
      var request = URLRequest(url: url, timeoutInterval: Double(timeout.components.seconds) + 1)
      request.setValue("bytes=\(input.offset)-\(input.offset + UInt64(input.limit) - 1)", forHTTPHeaderField: "Range")
      if let validator = known.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw NativeFileDownloadError.invalidResponse }
      if MediaLinkExpiry.isLinkRejection(statusCode: http.statusCode) {
        if attempt == 0, let fresh = await link.renewed(after: url) { url = fresh; continue }
        throw CDNRangeError.linkRejected(http.statusCode)
      }
      if (200 ... 299).contains(http.statusCode), !acceptsHTML, http.mimeType?.lowercased() == "text/html" {
        throw CDNRangeError.notTheFile
      }
      // A server that honored the first range answers a stale If-Range with the whole object.
      if known.validator != nil, http.statusCode == 200 { throw CDNRangeError.objectChanged }
      let part = try Self.part(
        for: input, status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"),
        // Only a size the server reported: legacy message metadata can be wrong, and a file that
        // fits one part would then never download. A web page is caught by its content type.
        data: data, expectedTotal: known.total
      )
      if http.statusCode == 206 { object.record(validator: Self.validator(http), total: part.totalSize) }
      return part
    }
    throw CDNRangeError.linkRejected(401)
  }

  /// A strong ETag, else Last-Modified: what `If-Range` may carry. A weak ETag may not.
  static func validator(_ response: HTTPURLResponse) -> String? {
    if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty, !etag.hasPrefix("W/") { return etag }
    return response.value(forHTTPHeaderField: "Last-Modified")
  }

  /// Turns one HTTP response into a range result, or throws when it is not exactly that range.
  /// `expectedTotal` is the file's size when known, from an earlier range or its message.
  static func part(
    for input: GetFilePartInput, status: Int, contentRange: String?, data: Data, expectedTotal: UInt64? = nil
  ) throws -> GetFilePartResult {
    let total: UInt64
    let body: Data
    switch status {
    case 206:
      guard let range = contentRange.flatMap(Self.parseContentRange), range.start == input.offset,
            range.end - range.start + 1 == UInt64(data.count)
      else { throw CDNRangeError.rangeNotSupported }
      total = range.total
      body = data
    case 200:
      // The whole file came back. Usable only when it is the range we asked for, and, when the
      // file's size is known, exactly that size: a short page in its place is not the file.
      guard input.offset == 0, data.count <= Int(input.limit) else { throw CDNRangeError.rangeNotSupported }
      if let expectedTotal, expectedTotal != UInt64(data.count) { throw CDNRangeError.notTheFile }
      total = UInt64(data.count)
      body = data
    case 416:
      // Past the end: only the EOF probe of an empty tail lands here.
      throw CDNRangeError.rangeNotSupported
    default:
      throw CDNRangeError.httpStatus(status)
    }
    var part = GetFilePartResult()
    part.offset = input.offset
    part.totalSize = total
    part.data = body
    part.sha256 = Data(SHA256.hash(data: body))
    return part
  }

  /// `bytes <start>-<end>/<total>`; an unknown total (`*`) is not usable.
  static func parseContentRange(_ value: String) -> (start: UInt64, end: UInt64, total: UInt64)? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
    let spec = trimmed.dropFirst("bytes ".count)
    let halves = spec.split(separator: "/", maxSplits: 1)
    guard halves.count == 2, let total = UInt64(halves[1]) else { return nil }
    let bounds = halves[0].split(separator: "-", maxSplits: 1)
    guard bounds.count == 2, let start = UInt64(bounds[0]), let end = UInt64(bounds[1]),
          start <= end, end < total
    else { return nil }
    return (start, end, total)
  }
}

/// The validator and size the first range reported, kept for the ranges after it.
final class CDNRangeObject: @unchecked Sendable {
  struct Known: Sendable {
    var validator: String?
    var total: UInt64?
  }

  private let lock = NSLock()
  private var known = Known()

  func current() -> Known { lock.withLock { known } }

  /// The first answer wins: the server holds later ranges to its validator through `If-Range`,
  /// and the download manager holds them to its total.
  func record(validator: String?, total: UInt64) {
    lock.withLock {
      if known.total == nil { known.total = total }
      if known.validator == nil { known.validator = validator }
    }
  }
}

/// What a native download produced. `fallback` is the native error that made the CDN finish
/// the file through the same partial, or nil when native finished it.
struct NativeDownloadOutcome: Sendable {
  let file: URL
  let fallback: (any Error)?
}

/// Native failed and the CDN range fallback failed after it. No further transport should run:
/// both already worked on the same partial.
struct NativeRangeFallbackFailure: Error {
  let native: any Error
  let cdn: any Error
}
