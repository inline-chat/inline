import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Optimistic rich text")
struct OptimisticRichTextTests {
  private func entity(_ type: MessageEntity.TypeEnum, _ offset: Int64, _ length: Int64) -> MessageEntity {
    .with { $0.type = type; $0.offset = offset; $0.length = length }
  }

  private func displayMath(_ offset: Int64, _ length: Int64) -> MessageEntity {
    .with { $0.type = .math; $0.offset = offset; $0.length = length; $0.math = .with { $0.display = true } }
  }

  private func entities(_ values: MessageEntity...) -> MessageEntities {
    .with { $0.entities = values }
  }

  @Test("Literal math gets canonical block ranges without interpreting Markdown or image syntax")
  func literalProjection() throws {
    let text = "😀 x^2 **bold** <u>literal</u> ![image](https://example.com/a.png)"
    let value = entities(entity(.math, 3, 3), entity(.bold, 7, 8))
    let payload = try #require(BlockContentPayload.literalBlocks(text: text, entities: value))
    #expect(payload.content.blocks.count == 1)
    let paragraph = try #require(payload.content.blocks.first?.paragraph)
    #expect(paragraph.offset == 0)
    #expect(paragraph.length == Int64(text.utf16.count))
    #expect(paragraph.hasIsRtl && !paragraph.isRtl)
    #expect(BlockContentPayload.literalBlocks(text: text, entities: nil) == nil)
    #expect(BlockContentPayload.literalBlocks(text: text, entities: entities(entity(.bold, 3, 3))) == nil)
    let persisted = try #require(BlockContentPayload.fromDatabaseValue(payload.databaseValue))
    #expect(persisted == payload)
  }

  @Test("Whole-line quotes match the server projection")
  func literalQuoteProjection() throws {
    let text = "before\nquoted one\n\nquoted two\nreply"
    let payload = try #require(BlockContentPayload.literalBlocks(text: text, entities: entities(entity(.blockquote, 7, 22))))
    #expect(payload.content.blocks.map(\.kind) == [
      .paragraph(.with { $0.length = 6; $0.isRtl = false }),
      .quote(.with {
        $0.children = [
          .with { $0.paragraph = .with { $0.offset = 7; $0.length = 10; $0.isRtl = false } },
          .with { $0.paragraph = .with { $0.offset = 19; $0.length = 10; $0.isRtl = false } },
        ]
        $0.isRtl = false
      }),
      .paragraph(.with { $0.offset = 30; $0.length = 5; $0.isRtl = false }),
    ])
    // A range that does not own whole lines, or crosses a code block, stays flat.
    #expect(BlockContentPayload.literalBlocks(text: text, entities: entities(entity(.blockquote, 8, 5))) == nil)
    #expect(BlockContentPayload.literalBlocks(
      text: text,
      entities: entities(entity(.blockquote, 7, 10), entity(.pre, 7, 22))
    ) == nil)
  }

  @Test("A reply keeps every quote in its body, in order")
  func replyKeepsQuotesInBody() throws {
    let text = "first\n\nsecond\nreply"
    let payload = try #require(BlockContentPayload.literalBlocks(
      text: text,
      entities: entities(entity(.blockquote, 0, 5), entity(.blockquote, 7, 6))
    ))
    #expect(payload.content.blocks.map(\.kind) == [
      .quote(.with {
        $0.children = [.with { $0.paragraph = .with { $0.length = 5; $0.isRtl = false } }]
        $0.isRtl = false
      }),
      .quote(.with {
        $0.children = [.with { $0.paragraph = .with { $0.offset = 7; $0.length = 6; $0.isRtl = false } }]
        $0.isRtl = false
      }),
      .paragraph(.with { $0.offset = 14; $0.length = 5; $0.isRtl = false }),
    ])
  }

  @Test("Highlighted text is found in a message even across blank lines")
  func quoteRangeInSource() {
    let source = "first line\n\nsecond line\nthird"
    #expect(ReplyQuote.range(of: "second line", in: source) == NSRange(location: 12, length: 11))
    // Quote lines are joined with one newline; the source has a blank line between them.
    #expect(ReplyQuote.range(of: "first line\nsecond line", in: source) == NSRange(location: 0, length: 23))
    // The last line is missing: the first line alone.
    #expect(ReplyQuote.range(of: "first line\nnot there", in: source) == NSRange(location: 0, length: 10))
    #expect(ReplyQuote.range(of: "missing", in: source) == nil)
    #expect(ReplyQuote.range(of: "\n \n", in: source) == nil)
  }

  @Test("A confirmed send from a server without quote blocks keeps the quote")
  func serverWithoutQuoteBlocks() throws {
    let text = "quoted\nreply"
    let echo = InlineProtocol.Message.with {
      $0.id = 2
      $0.chatID = 1
      $0.fromID = 1
      $0.message = text
      $0.replyToMsgID = 1
      $0.entities = entities(entity(.blockquote, 0, 6))
    }
    let blocks = try #require(InlineKit.Message(from: echo).blockContent?.blocks)
    #expect(blocks.count == 2)
    guard case .quote? = blocks.first?.kind else {
      Issue.record("expected the quote block first")
      return
    }

    // Blocks the server did send are kept as they are.
    let projected = InlineProtocol.Message.with {
      $0.message = text
      $0.entities = entities(entity(.blockquote, 0, 6))
      $0.blockContent = .with { $0.blocks = [.with { $0.paragraph = .with { $0.length = 12 } }] }
    }
    #expect(InlineKit.Message(from: projected).blockContent?.blocks.count == 1)
  }

  @Test("Display math keeps structural blocks only when the entity owns its line")
  func literalDisplayProjection() throws {
    let text = "before\nx\nafter"
    let displayEntities = entities(displayMath(7, 1))
    let encoded = try JSONEncoder().encode(displayEntities)
    #expect(try JSONDecoder().decode(MessageEntities.self, from: encoded) == displayEntities)
    let payload = try #require(BlockContentPayload.literalBlocks(text: text, entities: displayEntities))
    #expect(payload.content.blocks.map(\.kind) == [
      .paragraph(.with { $0.length = 6; $0.isRtl = false }),
      .math(.with { $0.offset = 7; $0.length = 1 }),
      .paragraph(.with { $0.offset = 9; $0.length = 5; $0.isRtl = false }),
    ])

    let mixed = try #require(BlockContentPayload.literalBlocks(
      text: "prefix x suffix", entities: entities(displayMath(7, 1))
    ))
    #expect(mixed.content.blocks.count == 1)
    #expect(mixed.content.blocks.first?.paragraph.length == 15)
  }

  @Test("Malformed UTF-16 ranges and code overlap cannot opt into formula rendering")
  func malformedAndCode() {
    let text = "😀 x^2"
    let invalid: [(Int64, Int64)] = [(-1, 1), (0, 0), (0, -1), (0, .max), (.max, 1), (0, 1), (1, 1), (6, 1)]
    for (offset, length) in invalid {
      #expect(BlockContentPayload.literalBlocks(text: text, entities: entities(entity(.math, offset, length))) == nil)
    }
    for type: MessageEntity.TypeEnum in [.code, .pre] {
      #expect(BlockContentPayload.literalBlocks(text: text, entities: entities(entity(.math, 3, 3), entity(type, 4, 1))) == nil)
    }
    // A malformed code range cannot suppress an otherwise valid formula.
    #expect(BlockContentPayload.literalBlocks(text: text, entities: entities(entity(.math, 3, 3), entity(.code, -1, 99))) != nil)
    #expect(BlockContentPayload.literalBlocks(text: String(repeating: "a", count: 131_073), entities: entities(entity(.math, 0, 1))) == nil)
  }

  @Test("Optimistic paragraph direction agrees with the server first-letter policy")
  func direction() throws {
    let cases: [(String, Bool?)] = [
      ("😀 ۱۲۳ فارسی x^2", true), ("\u{200E}123 עברית x^2", true),
      ("x^2 فارسی", false), ("中文 x^2", false), ("١٢٣ + 2", nil),
      ("\u{1E900} x^2", true), ("Ⅳ x^2", false),
    ]
    for (source, direction) in cases {
      let payload = try #require(BlockContentPayload.literalBlocks(text: source, entities: entities(entity(.math, 0, Int64(source.utf16.count)))))
      let span = try #require(payload.content.blocks.first?.paragraph)
      #expect(span.hasIsRtl == (direction != nil))
      if let direction { #expect(span.isRtl == direction) }
    }
  }

  @Test("Edits atomically update entity-only changes, invalidate old blocks and translations, and preserve true no-ops")
  func editPersistence() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 1, email: "author@example.com", firstName: "Author").insert(db)
      try Chat(id: 44, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Rich text", spaceId: nil).insert(db)
      let source = "x^2"
      let bold = entities(entity(.bold, 0, 3))
      let math = entities(entity(.math, 0, 3))
      let oldPayload = try #require(BlockContentPayload(.with {
        $0.blocks = [.with { $0.heading = .with { $0.level = 1; $0.text.length = 3 } }]
      }))
      let date = Date(timeIntervalSince1970: 10)
      let original = Message(messageId: 7, fromId: 1, date: date, text: source, peerUserId: nil,
                             peerThreadId: 44, chatId: 44, editDate: date, rev: 2,
                             blockContentPayload: oldPayload, entities: bold)
      try original.save(db)
      try Translation(messageId: 7, chatId: 44, translation: "old", entities: bold, language: "fa", date: date, msgRev: 2).save(db)
      func saved() throws -> InlineKit.Message { try #require(try Message.fetchOne(db, key: ["messageId": 7, "chatId": 44])) }
      func translations() throws -> Int { try Translation.fetchCount(db) }

      try EditMessageTransaction(message: original, text: source, entities: bold).applyOptimisticEdit(in: db)
      #expect(try saved().blockContentPayload == oldPayload)
      #expect(try saved().editDate == date)
      #expect(try translations() == 1)

      let editedAt = Date(timeIntervalSince1970: 20)
      try EditMessageTransaction(message: original, text: source, entities: math).applyOptimisticEdit(in: db, date: editedAt)
      var current = try saved()
      #expect(current.text == source && current.entities == math)
      #expect(current.blockContent?.blocks.first?.paragraph.length == 3)
      #expect(current.editDate == editedAt && current.rev == 2)
      #expect(try translations() == 0)

      // Server confirmation may match the already-saved source exactly.
      let acknowledgement = InlineProtocol.Message.with {
        $0.id = 7; $0.chatID = 44; $0.fromID = 1; $0.date = 10; $0.rev = 3
        $0.peerID = .with { $0.chat.chatID = 44 }; $0.message = source; $0.entities = math
        $0.blockContent = current.blockContent!
      }
      _ = try UpdateEditMessage.with { $0.message = acknowledgement }.apply(db, publishChanges: false)
      #expect(try translations() == 0)
      current = try saved()
      try EditMessageTransaction(message: current, text: source, entities: nil).applyOptimisticEdit(in: db)
      #expect(try saved().entities == nil)
      #expect(try saved().blockContent == nil)

      // Canonical-equivalent Swift strings can still have different UTF-16.
      try EditMessageTransaction(message: current, text: "é", entities: nil).applyOptimisticEdit(in: db)
      try EditMessageTransaction(message: current, text: "e\u{301}", entities: nil).applyOptimisticEdit(in: db)
      #expect(Array(try saved().text!.utf16) == [0x65, 0x301])
      try Translation(messageId: 7, chatId: 44, translation: "decomposed source", entities: nil,
                      language: "fa", date: date, msgRev: 3).save(db)
      var remoteEdit = acknowledgement
      remoteEdit.rev = 4
      remoteEdit.message = "é"
      remoteEdit.clearEntities()
      remoteEdit.clearBlockContent()
      _ = try UpdateEditMessage.with { $0.message = remoteEdit }.apply(db, publishChanges: false)
      #expect(Array(try saved().text!.utf16) == [0xE9])
      #expect(try translations() == 0)
    }
  }
}
