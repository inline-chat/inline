import Foundation

/// A logical text document. Surface boundaries are insertion boundaries;
/// barriers stop selection at unavailable history or a different text domain.
public struct TimelineTextSelection<Key: Hashable & Sendable>: Sendable {
  public enum Entry: Sendable {
    case surface(key: Key, text: String)
    case barrier
  }

  public enum Affinity: Equatable, Sendable {
    case upstream
    case downstream
  }

  public struct Endpoint: Equatable, Sendable {
    public let key: Key
    public let utf16Offset: Int
    public let affinity: Affinity

    public init(key: Key, utf16Offset: Int, affinity: Affinity = .downstream) {
      self.key = key
      self.utf16Offset = utf16Offset
      self.affinity = affinity
    }
  }

  public struct Projection: Sendable {
    public let anchor: Endpoint
    public let head: Endpoint
    /// Nonempty ranges; iterate orderedKeys for logical document order.
    public let ranges: [Key: NSRange]
    /// Every surface in the endpoint span, including empty interiors and
    /// zero-length endpoints. Copy uses these boundaries to retain separators.
    public let rangesIncludingEmptySurfaces: [Key: NSRange]
    public let orderedKeys: [Key]
    public var isEmpty: Bool {
      orderedKeys.isEmpty
    }

    fileprivate let span: [Entry]
  }

  private struct Position: Sendable {
    let index: Int
    let length: Int
  }

  public let entries: [Entry]
  private let positions: [Key: Position]

  /// Duplicate keys are ambiguous even when a barrier separates them.
  public init?(entries: [Entry]) {
    var positions: [Key: Position] = [:]
    for (index, entry) in entries.enumerated() {
      guard case let .surface(key, text) = entry else { continue }
      guard positions[key] == nil else { return nil }
      positions[key] = Position(index: index, length: text.utf16.count)
    }
    self.entries = entries
    self.positions = positions
  }

  /// Offsets outside a surface clamp to its ends. Inside a composed grapheme,
  /// affinity chooses the preceding or following insertion boundary. Missing
  /// keys fail rather than silently retargeting to another surface.
  public func project(anchor: Endpoint, head: Endpoint) -> Projection? {
    guard let anchorPosition = positions[anchor.key], let requestedHeadPosition = positions[head.key],
          case let .surface(_, anchorText) = entries[anchorPosition.index],
          case let .surface(_, headText) = entries[requestedHeadPosition.index] else { return nil }
    let anchor = normalized(anchor, text: anchorText, length: anchorPosition.length)
    var head = normalized(head, text: headText, length: requestedHeadPosition.length)
    let anchorIndex = anchorPosition.index
    var headIndex = requestedHeadPosition.index

    if anchorIndex < headIndex {
      for index in (anchorIndex + 1) ... headIndex {
        guard case .barrier = entries[index] else { continue }
        headIndex = index - 1
        guard case let .surface(key, _) = entries[headIndex], let position = positions[key] else { return nil }
        head = Endpoint(key: key, utf16Offset: position.length, affinity: .upstream)
        break
      }
    } else if headIndex < anchorIndex {
      for index in stride(from: anchorIndex - 1, through: headIndex, by: -1) {
        guard case .barrier = entries[index] else { continue }
        headIndex = index + 1
        guard case let .surface(key, _) = entries[headIndex] else { return nil }
        head = Endpoint(key: key, utf16Offset: 0, affinity: .downstream)
        break
      }
    }

    let lowerIndex = min(anchorIndex, headIndex)
    let upperIndex = max(anchorIndex, headIndex)
    let lowerOffset: Int
    let upperOffset: Int
    if anchorIndex == headIndex {
      lowerOffset = min(anchor.utf16Offset, head.utf16Offset)
      upperOffset = max(anchor.utf16Offset, head.utf16Offset)
    } else if anchorIndex < headIndex {
      lowerOffset = anchor.utf16Offset
      upperOffset = head.utf16Offset
    } else {
      lowerOffset = head.utf16Offset
      upperOffset = anchor.utf16Offset
    }
    var ranges: [Key: NSRange] = [:]
    var rangesIncludingEmptySurfaces: [Key: NSRange] = [:]
    var orderedKeys: [Key] = []
    for index in lowerIndex ... upperIndex {
      guard case let .surface(key, _) = entries[index], let position = positions[key] else { return nil }
      let start = index == lowerIndex ? lowerOffset : 0
      let end = index == upperIndex ? upperOffset : position.length
      let range = NSRange(location: start, length: end - start)
      rangesIncludingEmptySurfaces[key] = range
      if start < end {
        ranges[key] = range
        orderedKeys.append(key)
      }
    }
    return Projection(
      anchor: anchor, head: head, ranges: ranges,
      rangesIncludingEmptySurfaces: rangesIncludingEmptySurfaces, orderedKeys: orderedKeys,
      span: Array(entries[lowerIndex ... upperIndex])
    )
  }

  /// The endpoint span must remain contiguous and identical in logical order.
  /// Changes before or after it are harmless. Empty endpoint/interior surfaces
  /// remain part of the span, and edits anywhere in its sources invalidate it.
  public func isCompatible(with projection: Projection) -> Bool {
    guard let first = projection.span.first, case let .surface(firstKey, _) = first,
          let start = positions[firstKey]?.index,
          projection.span.count <= entries.count - start else { return false }
    for (offset, previous) in projection.span.enumerated() {
      guard case let .surface(previousKey, previousText) = previous,
            case let .surface(key, text) = entries[start + offset],
            key == previousKey,
            text.utf16.elementsEqual(previousText.utf16) else { return false }
    }
    return true
  }

  private func normalized(_ endpoint: Endpoint, text: String, length: Int) -> Endpoint {
    var offset = min(max(0, endpoint.utf16Offset), length)
    if offset > 0, offset < length {
      let source = text as NSString
      // NSString can expose the LF inside CRLF as a composed-sequence start.
      // Unicode grapheme boundaries keep this line-break pair indivisible.
      if source.character(at: offset - 1) == 0x0D, source.character(at: offset) == 0x0A {
        offset += endpoint.affinity == .upstream ? -1 : 1
      } else {
        let grapheme = source.rangeOfComposedCharacterSequence(at: offset)
        if offset != grapheme.location {
          switch endpoint.affinity {
            case .upstream: offset = grapheme.location
            case .downstream: offset = NSMaxRange(grapheme)
          }
        }
      }
    }
    return Endpoint(key: endpoint.key, utf16Offset: offset, affinity: endpoint.affinity)
  }
}
