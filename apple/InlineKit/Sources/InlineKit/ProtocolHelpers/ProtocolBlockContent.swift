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
  /// math projection without parsing Markdown or inventing media/block ranges.
  /// Call at the mutation boundary, never while measuring or rendering a row.
  static func literalMath(text: String?, entities: MessageEntities?) -> BlockContentPayload? {
    guard let text, let entities, entities.entities.contains(where: { $0.type == .math }),
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
    let math = entities.entities.compactMap { entity -> (MessageEntity, NSRange)? in
      guard entity.type == .math, let range = validRange(entity),
            !code.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return nil }
      return (entity, range)
    }
    guard !math.isEmpty else { return nil }

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
    var display: [NSRange] = math.compactMap { entity, range in
      guard case let .math(metadata)? = entity.entity, metadata.display else { return nil }
      let prefix = units[lineStart(range.location) ..< range.location]
      let suffix = units[NSMaxRange(range) ..< lineEnd(NSMaxRange(range))]
      guard prefix.count <= 3, prefix.allSatisfy({ $0 == 32 }),
            String(decoding: suffix, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return range
    }.sorted { $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length) }
    display = display.reduce(into: [NSRange]()) { result, range in
      if range.location >= (result.last.map(NSMaxRange) ?? 0) { result.append(range) }
    }

    var blocks: [Block] = []
    func appendParagraph(from initialStart: Int, to initialEnd: Int) {
      var start = initialStart, end = initialEnd
      while start < end, units[start] == 10 || units[start] == 13 { start += 1 }
      while end > start, units[end - 1] == 10 || units[end - 1] == 13 { end -= 1 }
      guard !String(decoding: units[start ..< end], as: UTF16.self)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      blocks.append(.with { block in
        block.paragraph = .with {
          $0.offset = Int64(start)
          $0.length = Int64(end - start)
          let paragraph = String(decoding: units[start ..< end], as: UTF16.self)
          if let isRTL = firstStrongIsRTL(paragraph) { $0.isRtl = isRTL }
        }
      })
    }
    var cursor = 0
    for range in display {
      appendParagraph(from: cursor, to: lineStart(range.location))
      blocks.append(.with { $0.math = .with { $0.offset = Int64(range.location); $0.length = Int64(range.length) } })
      cursor = consumeLineBreak(lineEnd(NSMaxRange(range)))
    }
    appendParagraph(from: cursor, to: units.count)
    if blocks.isEmpty {
      blocks.append(.with { block in
        block.paragraph = .with {
          $0.length = Int64(units.count)
          if let isRTL = firstStrongIsRTL(text) { $0.isRtl = isRTL }
        }
      })
    }
    return BlockContentPayload(.with { content in
      content.blocks = blocks
    })
  }

  // Same first-letter contract as server/modules/message/blockDirection.ts.
  // Neutral digits, marks and controls must not override Persian/Hebrew prose.
  private static func firstStrongIsRTL(_ text: String) -> Bool? {
    let rtlRanges: [ClosedRange<UInt32>] = [
      0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F,
      0x0780...0x07BF, 0x07C0...0x07FF, 0x0800...0x083F, 0x0840...0x085F,
      0x0860...0x086F, 0x0870...0x089F, 0x08A0...0x08FF, 0xFB1D...0xFB4F,
      0xFB50...0xFDFF, 0xFE70...0xFEFF, 0x10840...0x1085F, 0x10860...0x1087F,
      0x10880...0x108AF, 0x108E0...0x108FF, 0x10900...0x1091F, 0x10920...0x1093F,
      0x10980...0x109FF, 0x10A00...0x10A5F, 0x10A60...0x10A7F, 0x10A80...0x10A9F,
      0x10AC0...0x10AFF, 0x10B00...0x10B3F, 0x10B40...0x10B5F, 0x10B60...0x10B7F,
      0x10B80...0x10BAF, 0x10C00...0x10C4F, 0x10C80...0x10CFF, 0x10D00...0x10D8F,
      0x10E80...0x10EBF, 0x10F00...0x10FFF, 0x1E800...0x1E8DF, 0x1E900...0x1E95F,
      0x1EE00...0x1EEFF,
    ]
    for scalar in text.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber:
        return rtlRanges.contains { $0.contains(scalar.value) }
      default: continue
      }
    }
    return nil
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
