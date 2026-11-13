import Foundation
import GRDB
import InlineProtocol
import Logger

/// One durable protobuf payload plus its decoded value. Live protocol messages
/// create this at the transport/model boundary; GRDB recreates it once when a
/// persisted message is materialized. Rendering never decodes or serializes it.
public struct BlockContentPayload: Codable, Hashable, Sendable {
  public let content: InlineProtocol.BlockContent
  public let cacheSignature: Int
  public var byteCount: Int { payload.count }

  private let payload: Data

  public init?(_ content: InlineProtocol.BlockContent) {
    do {
      let payload = try content.serializedData()
      self.init(content: content, payload: payload)
    } catch {
      Log.shared.error("Failed to serialize BlockContent at protocol boundary", error: error)
      return nil
    }
  }

  /// Optimistic native input is already canonical. Match the server's literal
  /// math and quote projection without parsing Markdown or inventing media/block ranges.
  /// Call at the mutation boundary, never while measuring or rendering a row.
  static func literalBlocks(text: String?, entities: MessageEntities?) -> BlockContentPayload? {
    guard let text, let entities,
          entities.entities.contains(where: { $0.type == .math || $0.type == .blockquote }),
          !text.isEmpty, text.utf16.count <= 131_072 else { return nil }
    let units = Array(text.utf16)
    func validRange(_ entity: MessageEntity) -> NSRange? {
      guard entity.offset >= 0, entity.length > 0, entity.offset <= Int64(units.count),
            entity.length <= Int64(units.count) - entity.offset else { return nil }
      let start = Int(entity.offset), end = start + Int(entity.length)
      for offset in [start, end] where offset > 0 && offset < units.count {
        if (0xD800...0xDBFF).contains(units[offset - 1]), (0xDC00...0xDFFF).contains(units[offset]) {
          return nil
        }
      }
      return NSRange(location: start, length: end - start)
    }
    let code = entities.entities.filter { $0.type == .code || $0.type == .pre }.compactMap(validRange)
    let pre = entities.entities.filter { $0.type == .pre }.compactMap(validRange)
    let math = entities.entities.compactMap { entity -> (MessageEntity, NSRange)? in
      guard entity.type == .math, let range = validRange(entity),
            !code.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return nil }
      return (entity, range)
    }

    func lineStart(_ offset: Int) -> Int {
      var cursor = offset
      while cursor > 0, units[cursor - 1] != 10, units[cursor - 1] != 13 { cursor -= 1 }
      return cursor
    }
    func lineEnd(_ offset: Int) -> Int {
      var cursor = offset
      while cursor < units.count, units[cursor] != 10, units[cursor] != 13 { cursor += 1 }
      return cursor
    }
    func consumeLineBreak(_ offset: Int) -> Int {
      if offset < units.count, units[offset] == 13, offset + 1 < units.count, units[offset + 1] == 10 {
        return offset + 2
      }
      return offset < units.count && (units[offset] == 10 || units[offset] == 13) ? offset + 1 : offset
    }
    func isBlank(_ start: Int, _ end: Int) -> Bool {
      String(decoding: units[start ..< end], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    // A quote owns whole lines. It may contain inline code but never cuts through a PRE block.
    var quotes: [NSRange] = entities.entities.compactMap { entity in
      guard entity.type == .blockquote, let range = validRange(entity),
            lineStart(range.location) == range.location, lineEnd(NSMaxRange(range)) == NSMaxRange(range),
            !isBlank(range.location, NSMaxRange(range)),
            !pre.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return nil }
      return range
    }.sorted { $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length) }
    quotes = quotes.reduce(into: [NSRange]()) { result, range in
      if range.location >= (result.last.map(NSMaxRange) ?? 0) { result.append(range) }
    }
    guard !math.isEmpty || !quotes.isEmpty else { return nil }

    var display: [NSRange] = math.compactMap { entity, range in
      guard case let .math(metadata)? = entity.entity, metadata.display else { return nil }
      let prefix = units[lineStart(range.location) ..< range.location]
      let suffix = units[NSMaxRange(range) ..< lineEnd(NSMaxRange(range))]
      guard prefix.count <= 3, prefix.allSatisfy({ $0 == 32 }),
            String(decoding: suffix, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !quotes.contains(where: { NSIntersectionRange($0, range).length > 0 })
      else { return nil }
      return range
    }.sorted { $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length) }
    display = display.reduce(into: [NSRange]()) { result, range in
      if range.location >= (result.last.map(NSMaxRange) ?? 0) { result.append(range) }
    }

    func appendParagraph(to target: inout [Block], from initialStart: Int, to initialEnd: Int) {
      var start = initialStart, end = initialEnd
      while start < end, units[start] == 10 || units[start] == 13 { start += 1 }
      while end > start, units[end - 1] == 10 || units[end - 1] == 13 { end -= 1 }
      guard !isBlank(start, end) else { return }
      target.append(.with { block in
        block.paragraph = .with {
          $0.offset = Int64(start)
          $0.length = Int64(end - start)
          let paragraph = String(decoding: units[start ..< end], as: UTF16.self)
          if let isRTL = directionIsRTL(paragraph) { $0.isRtl = isRTL }
        }
      })
    }
    let sections = (display.map { (range: $0, isQuote: false) } + quotes.map { (range: $0, isQuote: true) })
      .sorted { $0.range.location < $1.range.location }

    var blocks: [Block] = []
    var cursor = 0
    for section in sections {
      let range = section.range
      appendParagraph(to: &blocks, from: cursor, to: lineStart(range.location))
      guard section.isQuote else {
        blocks.append(.with { $0.math = .with { $0.offset = Int64(range.location); $0.length = Int64(range.length) } })
        cursor = consumeLineBreak(lineEnd(NSMaxRange(range)))
        continue
      }
      // Blank lines inside a quote separate its paragraphs, as in Markdown.
      var children: [Block] = []
      var paragraphStart = range.location
      var line = range.location
      while line < NSMaxRange(range) {
        if isBlank(line, lineEnd(line)) {
          appendParagraph(to: &children, from: paragraphStart, to: line)
          paragraphStart = consumeLineBreak(lineEnd(line))
        }
        line = consumeLineBreak(lineEnd(line))
      }
      appendParagraph(to: &children, from: paragraphStart, to: NSMaxRange(range))
      blocks.append(.with { block in
        block.quote = .with {
          $0.children = children
          if let isRTL = children.lazy.compactMap({ $0.paragraph.hasIsRtl ? $0.paragraph.isRtl : nil }).first {
            $0.isRtl = isRTL
          }
        }
      })
      cursor = consumeLineBreak(NSMaxRange(range))
    }
    appendParagraph(to: &blocks, from: cursor, to: units.count)
    if blocks.isEmpty {
      blocks.append(.with { block in
        block.paragraph = .with {
          $0.length = Int64(units.count)
          if let isRTL = directionIsRTL(text) { $0.isRtl = isRTL }
        }
      })
    }
    return BlockContentPayload(.with { content in
      content.blocks = blocks
    })
  }

  // Same word-majority contract as server/modules/message/blockDirection.ts.
  private static func directionIsRTL(_ text: String) -> Bool? {
    BlockContentDirection.isRTL(text)
  }

  private init(content: InlineProtocol.BlockContent, payload: Data) {
    self.content = content
    self.payload = payload
    cacheSignature = payload.hashValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let payload = try container.decode(Data.self)
    content = try InlineProtocol.BlockContent(serializedBytes: payload)
    self.payload = payload
    cacheSignature = payload.hashValue
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(payload)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.payload == rhs.payload
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(cacheSignature)
    hasher.combine(payload.count)
  }
}

extension BlockContentPayload: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    payload.databaseValue
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> BlockContentPayload? {
    guard let payload = Data.fromDatabaseValue(dbValue) else { return nil }
    do {
      let content = try InlineProtocol.BlockContent(serializedBytes: payload)
      return BlockContentPayload(content: content, payload: payload)
    } catch {
      Log.shared.error("Failed to decode persisted BlockContent", error: error)
      return nil
    }
  }
}
