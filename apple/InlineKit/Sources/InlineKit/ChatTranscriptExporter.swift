import Foundation
import InlineProtocol
import RealtimeV2

public struct ChatTranscriptExport: Sendable, Equatable {
  public let markdown: String
  public let messageCount: Int
  public let fromMessageID: Int64?
  public let toMessageID: Int64?
  public let hasMore: Bool
  public let expiresAt: Int64?

  public init(
    markdown: String,
    messageCount: Int,
    fromMessageID: Int64?,
    toMessageID: Int64?,
    hasMore: Bool,
    expiresAt: Int64?
  ) {
    self.markdown = markdown
    self.messageCount = messageCount
    self.fromMessageID = fromMessageID
    self.toMessageID = toMessageID
    self.hasMore = hasMore
    self.expiresAt = expiresAt
  }
}

public enum ChatTranscriptExportError: Error {
  case invalidResponse
}

public enum ChatTranscriptExporter {
  public static let defaultLimit: Int32 = 500

  public static func latest(
    peer: Peer,
    realtime: RealtimeV2,
    limit: Int32 = defaultLimit
  ) async throws -> ChatTranscriptExport {
    try await page(peer: peer, beforeMessageID: nil, realtime: realtime, limit: limit)
  }

  public static func all(
    peer: Peer,
    startingWith latest: ChatTranscriptExport,
    realtime: RealtimeV2,
    limit: Int32 = defaultLimit
  ) async throws -> ChatTranscriptExport {
    try await all(startingWith: latest) { beforeMessageID in
      try await page(
        peer: peer,
        beforeMessageID: beforeMessageID,
        realtime: realtime,
        limit: limit
      )
    }
  }

  public static func all(
    startingWith latest: ChatTranscriptExport,
    fetchOlder: @Sendable (Int64) async throws -> ChatTranscriptExport
  ) async throws -> ChatTranscriptExport {
    var pages = [latest]
    var current = latest
    var seenBoundaries = Set<Int64>()

    while current.hasMore {
      try Task.checkCancellation()
      guard let boundary = current.fromMessageID, seenBoundaries.insert(boundary).inserted else {
        throw ChatTranscriptExportError.invalidResponse
      }
      let older = try await fetchOlder(boundary)
      if let olderBoundary = older.fromMessageID, olderBoundary >= boundary {
        throw ChatTranscriptExportError.invalidResponse
      }
      current = older
      pages.append(current)
    }

    return combine(pages: pages)
  }

  public static func combine(pages: [ChatTranscriptExport]) -> ChatTranscriptExport {
    guard let latest = pages.first else {
      return ChatTranscriptExport(
        markdown: "",
        messageCount: 0,
        fromMessageID: nil,
        toMessageID: nil,
        hasMore: false,
        expiresAt: nil
      )
    }

    let latestParts = splitDocument(latest.markdown)
    let bodies = pages.reversed().map { splitDocument($0.markdown).body }
    let markdown = latestParts.header + conversationMarker + bodies.joined(separator: "\n\n")
    let expirations = pages.compactMap(\.expiresAt)

    return ChatTranscriptExport(
      markdown: markdown,
      messageCount: pages.reduce(0) { $0 + $1.messageCount },
      fromMessageID: pages.last?.fromMessageID,
      toMessageID: latest.toMessageID,
      hasMore: pages.last?.hasMore ?? false,
      expiresAt: expirations.min()
    )
  }

  private static func page(
    peer: Peer,
    beforeMessageID: Int64?,
    realtime: RealtimeV2,
    limit: Int32
  ) async throws -> ChatTranscriptExport {
    let rpcResult = try await realtime.send(
      .getChatTranscript(peer: peer, beforeMessageID: beforeMessageID, limit: limit)
    )
    guard case let .getChatTranscript(result) = rpcResult else {
      throw ChatTranscriptExportError.invalidResponse
    }

    return ChatTranscriptExport(
      markdown: result.markdown,
      messageCount: Int(result.messageCount),
      fromMessageID: result.hasFromMessageID ? result.fromMessageID : nil,
      toMessageID: result.hasToMessageID ? result.toMessageID : nil,
      hasMore: result.hasMore_p,
      expiresAt: result.hasExpiresAt ? result.expiresAt : nil
    )
  }

  private static let conversationMarker = "## Conversation\n\n"

  private static func splitDocument(_ markdown: String) -> (header: String, body: String) {
    guard let range = markdown.range(of: conversationMarker) else {
      return ("", markdown)
    }
    return (String(markdown[..<range.lowerBound]), String(markdown[range.upperBound...]))
  }
}
