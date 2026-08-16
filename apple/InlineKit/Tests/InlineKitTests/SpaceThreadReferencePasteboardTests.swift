import Foundation
import Testing
@testable import InlineKit

@Suite("Thread Reference Pasteboard")
struct ThreadReferencePasteboardTests {
  @Test("builds plain, Inline, URL, HTML, and Markdown clipboard representations")
  func buildsRichClipboardRepresentations() throws {
    let reference = ThreadReference(chatId: 42, number: 123)
    let content = try #require(ThreadReferencePasteboard.content(for: reference))

    #expect(content.plainText == "#123")
    #expect(content.url.absoluteString == "https://inline.chat/c/42")
    #expect(content.html == #"<a href="https://inline.chat/c/42">#123</a>"#)
    #expect(content.markdown == "[#123](https://inline.chat/c/42)")
    #expect(try JSONDecoder().decode(ThreadReference.self, from: content.inlineData) == reference)
  }

  @Test("rejects invalid clipboard references")
  func rejectsInvalidClipboardReferences() {
    #expect(ThreadReferencePasteboard.content(
      for: ThreadReference(chatId: 0, number: 123)
    ) == nil)
    #expect(ThreadReferencePasteboard.content(
      for: ThreadReference(chatId: 42, number: 0)
    ) == nil)
  }

  @Test("accepts only the current number for an existing scoped thread")
  func acceptsOnlyCurrentThreadReference() async throws {
    let database = AppDatabase.empty()
    let reference = ThreadReference(chatId: 42, number: 123)

    #expect(!ThreadReferencePasteboard.isCurrent(reference, database: database))

    try await database.dbWriter.write { db in
      try Space(id: 7, name: "Engineering", date: Date(timeIntervalSince1970: 1)).insert(db)
      try Chat(
        id: reference.chatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Planning",
        spaceId: 7,
        number: reference.number
      ).insert(db)
    }

    #expect(ThreadReferencePasteboard.isCurrent(reference, database: database))
    #expect(!ThreadReferencePasteboard.isCurrent(
      ThreadReference(chatId: reference.chatId, number: 124),
      database: database
    ))
    #expect(!ThreadReferencePasteboard.isCurrent(
      ThreadReference(chatId: 43, number: reference.number),
      database: database
    ))
  }

  @Test("accepts a current user-scoped thread reference")
  func acceptsCurrentUserScopedThreadReference() async throws {
    let database = AppDatabase.empty()
    let reference = ThreadReference(chatId: 52, number: 7)

    try await database.dbWriter.write { db in
      try User(
        id: 9,
        email: "mo@example.com",
        firstName: "Mo",
        username: "mo"
      ).insert(db)
      try Chat(
        id: reference.chatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "DM reply",
        spaceId: nil,
        number: reference.number,
        createdBy: 9
      ).insert(db)
    }

    #expect(ThreadReferencePasteboard.isCurrent(reference, database: database))
  }
}
