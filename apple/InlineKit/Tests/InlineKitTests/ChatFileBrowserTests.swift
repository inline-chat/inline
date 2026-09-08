import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Chat file browser")
struct ChatFileBrowserTests {
  private func document(
    _ id: Int64,
    chat: Int64 = 42,
    asset: Int64 = 9,
    name: String = "Spec.pdf",
    mime: String = "application/pdf"
  ) -> InlineProtocol.Message {
    .with {
      $0.id = id
      $0.chatID = chat
      $0.peerID = .with { $0.type = .chat(.with { $0.chatID = chat }) }
      $0.date = id * 10
      $0.media = .with {
        $0.media = .document(.with {
          $0.document = .with { $0.id = asset
            $0.fileName = name
            $0.mimeType = mime
            $0.size = Int32(id)
          }
        })
      }
    }
  }

  private func photo(_ id: Int64, sticker: Bool = false) -> InlineProtocol.Message {
    .with {
      $0.id = id
      $0.chatID = 42
      $0.isSticker = sticker
      $0.media = .with { $0.media = .photo(.with { $0.photo = .with { $0.id = id } }) }
    }
  }

  @Test func sharingOccurrencesKeepTheirOwnIdentity() throws {
    let a = try #require(ChatFileEntry(document(4)))
    let b = try #require(ChatFileEntry(document(3)))
    let c = try #require(ChatFileEntry(document(4, chat: 50)))
    #expect(Set([a.id, b.id, c.id]).count == 3)
    let page = try ChatFileListing().appending(documents: [document(4), document(3)], media: [], chatID: 42)
    #expect(page.entries.count == 2)
    #expect(page.isComplete)
  }

  @Test func documentMimeTypesParticipateInMediaFilters() {
    #expect(ChatFileEntry(document(1, mime: "image/png"))?.kind == .image)
    #expect(ChatFileEntry(document(2, mime: "VIDEO/MP4"))?.kind == .video)
    #expect(ChatFileEntry(document(3))?.kind == .file)
  }

  @Test func stickerOnlyPageAdvancesWithoutFalseCompletion() throws {
    let raw = (51 ... 100).reversed().map { photo(Int64($0), sticker: true) }
    let page = try ChatFileListing().appending(documents: [], media: raw, chatID: 42)
    #expect(page.entries.isEmpty)
    #expect(page.documents.isComplete)
    #expect(!page.isComplete)
    #expect(page.media.beforeID == 51)
    let end = try page.appending(documents: nil, media: [photo(50)], chatID: 42)
    #expect(end.isComplete)
    #expect(end.entries.count == 1)
  }

  @Test func cursorsAdvanceIndependentlyAndUseMessageIDs() throws {
    var newest = document(100)
    newest.date = 1 // A backdated message must not change traversal.
    let documents = [newest] + (51 ... 99).reversed().map { document(Int64($0)) }
    let first = try ChatFileListing().appending(documents: documents, media: [photo(17)], chatID: 42)
    #expect(first.documents.beforeID == 51)
    #expect(!first.documents.isComplete)
    #expect(first.media.isComplete)
    let last = try first.appending(documents: [document(50)], media: nil, chatID: 42)
    #expect(last.entries.count == 52)
    #expect(last.isComplete)
  }

  @Test func malformedPagesDoNotAdvanceState() {
    let initial = ChatFileListing()
    #expect(throws: ChatFileBrowserError.self) {
      try initial.appending(documents: [document(3, chat: 99)], media: [], chatID: 42)
    }
    #expect(throws: ChatFileBrowserError.self) {
      try initial.appending(documents: [document(2), document(3)], media: [], chatID: 42)
    }
    #expect(throws: ChatFileBrowserError.self) {
      try initial.appending(documents: [photo(3)], media: [], chatID: 42)
    }
    #expect(initial.entries.isEmpty)
    #expect(initial.documents.beforeID == nil)
  }

  @Test func sortingUsesNaturalNamesAndNumericSizes() throws {
    let entries = try [document(2, name: "File 10.pdf"), document(10, name: "File 2.pdf")]
      .map { try #require(ChatFileEntry($0)) }
    #expect(ChatFileEntry.sorted(entries, by: .name, ascending: true).first?.name == "File 2.pdf")
    #expect(ChatFileEntry.sorted(entries, by: .size, ascending: false).first?.size == 10)
    #expect(ChatFileEntry.sorted(entries, by: .date, ascending: true).first?.id.messageID == 2)
  }
}
