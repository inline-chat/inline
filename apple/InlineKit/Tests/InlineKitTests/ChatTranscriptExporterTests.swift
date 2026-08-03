@testable import InlineKit
import Testing

@Suite("Chat transcript exporter")
struct ChatTranscriptExporterTests {
  @Test("combines older pages before the latest page without repeating headers")
  func combinesPages() throws {
    let latest = page(
      "# Chat\n\n[Open](<in://chat/1>)\n\n## Conversation\n\n**Mo**\n\nLatest",
      count: 1,
      from: 3,
      to: 3,
      hasMore: true,
      expiresAt: 200
    )
    let older = page(
      "# Chat\n\n[Open](<in://chat/1>)\n\n## Conversation\n\n**Dena**\n\nEarlier",
      count: 1,
      from: 2,
      to: 2,
      hasMore: false,
      expiresAt: 150
    )

    let result = ChatTranscriptExporter.combine(pages: [latest, older])

    #expect(result.markdown.components(separatedBy: "# Chat").count == 2)
    let earlierRange = try #require(result.markdown.firstRange(of: "Earlier"))
    let latestRange = try #require(result.markdown.firstRange(of: "Latest"))
    #expect(earlierRange.lowerBound < latestRange.lowerBound)
    #expect(result.messageCount == 2)
    #expect(result.fromMessageID == 2)
    #expect(result.toMessageID == 3)
    #expect(result.expiresAt == 150)
  }

  @Test("uses the earliest returned message as the explicit continuation boundary")
  func followsExplicitBoundary() async throws {
    let latest = page(
      "# Chat\n\n## Conversation\n\nLatest",
      count: 1,
      from: 3,
      to: 3,
      hasMore: true,
      expiresAt: 200
    )
    let older = page(
      "# Chat\n\n## Conversation\n\nEarlier",
      count: 1,
      from: 2,
      to: 2,
      hasMore: false,
      expiresAt: 150
    )

    let result = try await ChatTranscriptExporter.all(startingWith: latest) { beforeMessageID in
      #expect(beforeMessageID == 3)
      return older
    }

    #expect(result.messageCount == 2)
    #expect(result.fromMessageID == 2)
    #expect(result.hasMore == false)
  }

  @Test("rejects a continuation page that does not move backward")
  func rejectsNonDecreasingBoundary() async throws {
    let latest = page(
      "# Chat\n\n## Conversation\n\nLatest",
      count: 1,
      from: 3,
      to: 3,
      hasMore: true,
      expiresAt: 200
    )

    await #expect(throws: ChatTranscriptExportError.self) {
      _ = try await ChatTranscriptExporter.all(startingWith: latest) { _ in latest }
    }
  }

  private func page(
    _ markdown: String,
    count: Int,
    from: Int64,
    to: Int64,
    hasMore: Bool,
    expiresAt: Int64
  ) -> ChatTranscriptExport {
    ChatTranscriptExport(
      markdown: markdown,
      messageCount: count,
      fromMessageID: from,
      toMessageID: to,
      hasMore: hasMore,
      expiresAt: expiresAt
    )
  }
}
