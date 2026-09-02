import Foundation

/// Pure range planning for a selection rendered by several native text views.
/// View ownership, pointer tracking, and pasteboard export remain platform code.
public enum RichTextMultiSurfaceSelection {
  public struct Endpoint: Equatable, Sendable {
    public let surfaceIndex: Int
    public let utf16Offset: Int

    public init(surfaceIndex: Int, utf16Offset: Int) {
      self.surfaceIndex = surfaceIndex
      self.utf16Offset = utf16Offset
    }
  }

  public struct DocumentItem: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
      case surface(Int)
      /// `leadingForSurface` associates a synthetic prefix such as a list
      /// marker with the following native text surface.
      case literal(Int, leadingForSurface: Int?)
    }

    public let content: Content
    public let separatorAfter: String

    public init(content: Content, separatorAfter: String) {
      self.content = content
      self.separatorAfter = separatorAfter
    }
  }

  public enum DocumentPart: Equatable, Sendable {
    case surface(index: Int, range: NSRange)
    case literal(Int)
    case separator(String)
  }

  /// Returns one local UTF-16 range per surface. Unselected surfaces are nil.
  /// Invalid topology fails closed; endpoint offsets clamp like native carets.
  public static func ranges(
    surfaceLengths: [Int],
    anchor: Endpoint,
    head: Endpoint
  ) -> [NSRange?]? {
    guard !surfaceLengths.isEmpty,
          surfaceLengths.allSatisfy({ $0 >= 0 }),
          surfaceLengths.indices.contains(anchor.surfaceIndex),
          surfaceLengths.indices.contains(head.surfaceIndex)
    else { return nil }

    let anchor = Endpoint(
      surfaceIndex: anchor.surfaceIndex,
      utf16Offset: min(max(0, anchor.utf16Offset), surfaceLengths[anchor.surfaceIndex])
    )
    let head = Endpoint(
      surfaceIndex: head.surfaceIndex,
      utf16Offset: min(max(0, head.utf16Offset), surfaceLengths[head.surfaceIndex])
    )
    let lower: Endpoint
    let upper: Endpoint
    if anchor.surfaceIndex < head.surfaceIndex
      || (anchor.surfaceIndex == head.surfaceIndex && anchor.utf16Offset <= head.utf16Offset)
    {
      lower = anchor
      upper = head
    } else {
      lower = head
      upper = anchor
    }

    var result = Array<NSRange?>(repeating: nil, count: surfaceLengths.count)
    if lower.surfaceIndex == upper.surfaceIndex {
      result[lower.surfaceIndex] = NSRange(
        location: lower.utf16Offset,
        length: upper.utf16Offset - lower.utf16Offset
      )
      return result
    }

    for index in lower.surfaceIndex ... upper.surfaceIndex {
      let start = index == lower.surfaceIndex ? lower.utf16Offset : 0
      let end = index == upper.surfaceIndex ? upper.utf16Offset : surfaceLengths[index]
      result[index] = NSRange(location: start, length: max(0, end - start))
    }
    return result
  }

  /// Projects native per-surface ranges into semantic document order. Literal
  /// items model content without a text view (list markers and rendered math),
  /// while separators preserve table and block structure.
  public static func documentParts(
    document: [DocumentItem],
    surfaceRanges: [NSRange?],
    includeDocumentEdges: Bool = false
  ) -> [DocumentPart]? {
    guard !document.isEmpty, !surfaceRanges.isEmpty else { return nil }

    var orderedSurfaceIndices: [Int] = []
    for item in document {
      switch item.content {
      case let .surface(index):
        guard surfaceRanges.indices.contains(index) else { return nil }
        orderedSurfaceIndices.append(index)
      case let .literal(index, leadingForSurface):
        guard index >= 0 else { return nil }
        if let leadingForSurface, !surfaceRanges.indices.contains(leadingForSurface) { return nil }
      }
    }
    guard orderedSurfaceIndices == Array(surfaceRanges.indices) else { return nil }

    let selectedSurfacePositions = document.indices.compactMap { position -> Int? in
      guard case let .surface(index) = document[position].content,
            surfaceRanges[index] != nil
      else { return nil }
      return position
    }
    guard let firstSurfacePosition = selectedSurfacePositions.first,
          let lastSurfacePosition = selectedSurfacePositions.last
    else { return nil }

    let crossesSurfaces = firstSurfacePosition != lastSurfacePosition
    let hasCharacters = surfaceRanges.contains { ($0?.length ?? 0) > 0 }
    guard crossesSurfaces || hasCharacters else { return nil }

    var lower = includeDocumentEdges ? document.startIndex : firstSurfacePosition
    let upper = includeDocumentEdges ? document.index(before: document.endIndex) : lastSurfacePosition
    if !includeDocumentEdges,
       case let .surface(firstSurfaceIndex) = document[firstSurfacePosition].content,
       surfaceRanges[firstSurfaceIndex]?.location == 0
    {
      while lower > document.startIndex {
        let previous = document.index(before: lower)
        guard case let .literal(_, leadingForSurface) = document[previous].content,
              leadingForSurface == firstSurfaceIndex
        else { break }
        lower = previous
      }
    }

    var parts: [DocumentPart] = []
    for position in lower ... upper {
      let item = document[position]
      switch item.content {
      case let .surface(index):
        guard let range = surfaceRanges[index], range.location >= 0, range.length >= 0 else { return nil }
        if range.length > 0 { parts.append(.surface(index: index, range: range)) }
      case let .literal(index, _):
        parts.append(.literal(index))
      }
      if position != upper, !item.separatorAfter.isEmpty {
        parts.append(.separator(item.separatorAfter))
      }
    }
    return parts.isEmpty ? nil : parts
  }

  public static func attributedText(
    document: [DocumentItem],
    surfaceTexts: [NSAttributedString],
    surfaceRanges: [NSRange?],
    literals: [NSAttributedString],
    includeDocumentEdges: Bool = false
  ) -> NSAttributedString? {
    guard surfaceTexts.count == surfaceRanges.count,
          let parts = documentParts(
            document: document,
            surfaceRanges: surfaceRanges,
            includeDocumentEdges: includeDocumentEdges
          )
    else { return nil }

    let result = NSMutableAttributedString()
    for part in parts {
      switch part {
      case let .surface(index, range):
        guard surfaceTexts.indices.contains(index),
              let source = RichTextMath.sourceAttributedText(surfaceTexts[index], range: range)
        else { return nil }
        result.append(source)
      case let .literal(index):
        guard literals.indices.contains(index) else { return nil }
        result.append(literals[index])
      case let .separator(separator):
        result.append(NSAttributedString(string: separator))
      }
    }
    return result.length > 0 ? result : nil
  }
}
