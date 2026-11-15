import CryptoKit
import Foundation
import InlineProtocol

/// HTTP failures from the CDN range source, classified for the download engine's retry policy.
enum CDNRangeError: Error, Equatable, Sendable {
  /// The CDN answered with this status. 408, 429 and 5xx are transient.
  case httpStatus(Int)
  /// The CDN ignored or mangled the requested range.
  case rangeNotSupported
  /// The link was rejected, and a refreshed one was too or could not be had.
  case linkRejected(Int)

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
/// the whole-file CDN path.
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

  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    guard input.limit > 0 else { throw NativeFileDownloadError.invalidRequest }
    var url = await link.current()
    for attempt in 0 ... 1 {
      var request = URLRequest(url: url, timeoutInterval: Double(timeout.components.seconds) + 1)
      request.setValue("bytes=\(input.offset)-\(input.offset + UInt64(input.limit) - 1)", forHTTPHeaderField: "Range")
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw NativeFileDownloadError.invalidResponse }
      if MediaLinkExpiry.isLinkRejection(statusCode: http.statusCode) {
        if attempt == 0, let fresh = await link.renewed(after: url) { url = fresh; continue }
        throw CDNRangeError.linkRejected(http.statusCode)
      }
      return try Self.part(for: input, status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"), data: data)
    }
    throw CDNRangeError.linkRejected(401)
  }

  /// Turns one HTTP response into a range result, or throws when it is not exactly that range.
  static func part(for input: GetFilePartInput, status: Int, contentRange: String?, data: Data) throws -> GetFilePartResult {
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
      // The whole file came back. Usable only when it is the range we asked for.
      guard input.offset == 0, data.count <= Int(input.limit) else { throw CDNRangeError.rangeNotSupported }
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
