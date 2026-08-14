import Foundation
import Testing
@testable import InlineKit

@Suite("Space Thread Reference Pasteboard")
struct SpaceThreadReferencePasteboardTests {
  @Test("builds plain, Inline, URL, HTML, and Markdown clipboard representations")
  func buildsRichClipboardRepresentations() throws {
    let reference = SpaceThreadReference(chatId: 42, number: 123)
    let content = try #require(SpaceThreadReferencePasteboard.content(for: reference))

    #expect(content.plainText == "#123")
    #expect(content.url.absoluteString == "https://inline.chat/c/42")
    #expect(content.html == #"<a href="https://inline.chat/c/42">#123</a>"#)
    #expect(content.markdown == "[#123](https://inline.chat/c/42)")
    #expect(try JSONDecoder().decode(SpaceThreadReference.self, from: content.inlineData) == reference)
  }

  @Test("rejects invalid clipboard references")
  func rejectsInvalidClipboardReferences() {
    #expect(SpaceThreadReferencePasteboard.content(
      for: SpaceThreadReference(chatId: 0, number: 123)
    ) == nil)
    #expect(SpaceThreadReferencePasteboard.content(
      for: SpaceThreadReference(chatId: 42, number: 0)
    ) == nil)
  }

  @Test("accepts only the current number for an existing space thread")
  func acceptsOnlyCurrentSpaceThreadReference() async throws {
    let database = AppDatabase.empty()
    let reference = SpaceThreadReference(chatId: 42, number: 123)

    #expect(!SpaceThreadReferencePasteboard.isCurrent(reference, database: database))

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

    #expect(SpaceThreadReferencePasteboard.isCurrent(reference, database: database))
    #expect(!SpaceThreadReferencePasteboard.isCurrent(
      SpaceThreadReference(chatId: reference.chatId, number: 124),
      database: database
    ))
    #expect(!SpaceThreadReferencePasteboard.isCurrent(
      SpaceThreadReference(chatId: 43, number: reference.number),
      database: database
    ))
  }
}
