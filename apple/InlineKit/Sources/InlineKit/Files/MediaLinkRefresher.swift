import Foundation
import Logger

/// Signed media links expire: the server signs them for a week. Downloaders read links from
/// stored messages, so an old message keeps handing out a dead link until it is fetched again.
public enum MediaLinkExpiry {
  private static let amzDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()

  /// Reads the expiry from either format the server signs: the media proxy's `exp`, or R2's
  /// `X-Amz-Date` plus `X-Amz-Expires`. Returns nil for links that carry neither.
  public static func expiryDate(_ url: URL?) -> Date? {
    guard let url, !url.isFileURL,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    func value(_ name: String) -> String? {
      items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    if let exp = value("exp").flatMap(TimeInterval.init) {
      return Date(timeIntervalSince1970: exp)
    }
    if let signed = value("X-Amz-Date").flatMap(amzDateFormatter.date(from:)),
       let lifetime = value("X-Amz-Expires").flatMap(TimeInterval.init)
    {
      return signed.addingTimeInterval(lifetime)
    }
    return nil
  }

  /// Links without an expiry are treated as not expiring.
  public static func isExpired(_ url: URL?, margin: TimeInterval = 5 * 60, now: Date = Date()) -> Bool {
    guard let expiry = expiryDate(url) else { return false }
    return expiry < now.addingTimeInterval(margin)
  }

  /// The server answers an expired or revoked link with 401, 403 or 410.
  public static func isLinkRejection(statusCode: Int) -> Bool {
    statusCode == 401 || statusCode == 403 || statusCode == 410
  }
}

/// Re-fetches a message so the database receives freshly signed media links.
///
/// Concurrent requests for one message share a single fetch, and a message is fetched at most
/// once a minute, so a view that keeps reappearing cannot turn a dead link into a request storm.
public actor MediaLinkRefresher {
  public typealias Fetch = @Sendable (Peer, Int64) async throws -> Void

  public static let shared = MediaLinkRefresher { peer, messageId in
    _ = try await Api.realtime.send(.getMessages(peer: peer, messageIds: [messageId]))
  }

  private struct Key: Hashable {
    let peer: Peer
    let messageId: Int64
  }

  private let fetch: Fetch
  private let minimumInterval: TimeInterval
  private var inFlight: [Key: Task<Bool, Never>] = [:]
  private var lastFinished: [Key: Date] = [:]
  private let log = Log.scoped("MediaLinkRefresher")

  public init(minimumInterval: TimeInterval = 60, fetch: @escaping Fetch) {
    self.minimumInterval = minimumInterval
    self.fetch = fetch
  }

  /// Returns true when the message was fetched; the caller then re-reads its link from the
  /// database. Returns false when the fetch failed or ran too recently to repeat; the stored
  /// link may still be newer than the caller's, from that recent fetch.
  public func refresh(peer: Peer, messageId: Int64) async -> Bool {
    guard messageId > 0 else { return false }
    let key = Key(peer: peer, messageId: messageId)
    if let task = inFlight[key] { return await task.value }
    if let last = lastFinished[key], Date().timeIntervalSince(last) < minimumInterval { return false }

    let fetch = fetch
    let log = log
    let task = Task<Bool, Never> {
      do {
        try await fetch(peer, messageId)
        return true
      } catch {
        log.warning("Failed to refresh media links for message \(messageId): \(error.localizedDescription)")
        return false
      }
    }
    inFlight[key] = task
    let refreshed = await task.value
    inFlight[key] = nil
    lastFinished[key] = Date()
    return refreshed
  }
}
