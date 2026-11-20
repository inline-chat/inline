import CoreGraphics
import Foundation

/// Text typeset as several blocks, like a rich message's paragraphs, list items, code and table
/// cells, selected as one run in reading order. Surfaces join end to end: a flat index counts
/// every surface's UTF-16 characters with nothing between them, so a selection is one
/// `NSRange`. Geometry is in the selection's coordinates, y-down.
public struct TextSelectionSurfaces: Sendable {
  public struct Surface: Sendable {
    public var layout: TextLayout
    /// Where the layout's origin sits.
    public var origin: CGPoint
    /// The part that shows of text scrolling inside a box (code, tables); nil when it all shows.
    public var visibleRect: CGRect?

    public init(layout: TextLayout, origin: CGPoint, visibleRect: CGRect? = nil) {
      self.layout = layout
      self.origin = origin
      self.visibleRect = visibleRect
    }

    /// The text's box, cut to what shows; nil when none of it does.
    public var frame: CGRect? {
      let frame = CGRect(origin: origin, size: layout.size)
      guard let visibleRect else { return frame }
      let visible = frame.intersection(visibleRect)
      return visible.isNull || visible.isEmpty ? nil : visible
    }

    fileprivate var isSelectable: Bool { layout.length > 0 && !layout.lines.isEmpty && frame != nil }

    fileprivate func local(_ point: CGPoint) -> CGPoint {
      var point = point
      // Past a scrolling box's edge the text doesn't show; carets stop at what does.
      if let visibleRect, let frame {
        point.x = min(max(point.x, frame.minX), frame.maxX)
        point.y = min(max(point.y, visibleRect.minY), visibleRect.maxY)
      }
      return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
  }

  public let surfaces: [Surface]
  /// Each surface's first character in the flat index.
  public let starts: [Int]
  public let length: Int

  public init(_ surfaces: [Surface]) {
    self.surfaces = surfaces
    var starts: [Int] = []
    var length = 0
    for surface in surfaces {
      starts.append(length)
      length += surface.layout.length
    }
    self.starts = starts
    self.length = length
  }

  /// One block of text at `origin`.
  public init(layout: TextLayout, origin: CGPoint) {
    self.init([Surface(layout: layout, origin: origin)])
  }

  public var isEmpty: Bool { !surfaces.contains { $0.isSelectable } }

  /// The surface and its own index for a flat `index`. Where one surface ends and the next
  /// begins, `.downstream` takes the later one (a selection's start) and `.upstream` the
  /// earlier one (its end).
  public func location(of index: Int, affinity: TextCaretAffinity) -> (surface: Int, offset: Int)? {
    let index = min(max(index, 0), length)
    let selectable = surfaces.indices.filter { surfaces[$0].isSelectable }
    guard let first = selectable.first, let last = selectable.last else { return nil }
    switch affinity {
    case .downstream:
      if let surface = selectable.first(where: { index < starts[$0] + surfaces[$0].layout.length }) {
        return (surface, max(0, index - starts[surface]))
      }
      return (last, surfaces[last].layout.length)
    case .upstream:
      if let surface = selectable.first(where: { starts[$0] < index && index <= starts[$0] + surfaces[$0].layout.length }) {
        return (surface, index - starts[surface])
      }
      if index <= starts[first] { return (first, 0) }
      // Between surfaces, after empty ones: the end of the last surface before it.
      if let surface = selectable.last(where: { starts[$0] + surfaces[$0].layout.length <= index }) {
        return (surface, surfaces[surface].layout.length)
      }
      return (first, 0)
    }
  }

  // MARK: - Hit testing

  /// The surface a press at `point` lands on: the nearest whose text is within `padding`.
  public func surface(at point: CGPoint, padding: CGFloat) -> Int? {
    var best: (index: Int, distance: CGFloat)?
    for (index, surface) in surfaces.enumerated() where surface.isSelectable {
      guard let frame = surface.frame, frame.insetBy(dx: -padding, dy: -padding).contains(point) else { continue }
      let distance = Self.distance(from: point, to: frame)
      if best == nil || distance < best!.distance { best = (index, distance) }
    }
    return best?.index
  }

  /// The surface a drag at `point` belongs to: the one under it, else the nearest on its row,
  /// else the nearest above or below. Table cells share rows, so sideways distance decides
  /// among them.
  public func nearestSurface(to point: CGPoint) -> Int? {
    var best: (index: Int, dy: CGFloat, dx: CGFloat)?
    for (index, surface) in surfaces.enumerated() where surface.isSelectable {
      guard let frame = surface.frame else { continue }
      let dy = max(frame.minY - point.y, point.y - frame.maxY, 0)
      let dx = max(frame.minX - point.x, point.x - frame.maxX, 0)
      if let current = best, dy > current.dy || (dy == current.dy && dx >= current.dx) { continue }
      best = (index, dy, dx)
    }
    return best?.index
  }

  /// Flat caret index nearest `point`.
  public func closestIndex(to point: CGPoint) -> Int {
    guard let index = nearestSurface(to: point) else { return 0 }
    let surface = surfaces[index]
    let local = surface.local(point)
    var caret = surface.layout.closestCaretIndex(to: local)
    // At a scrolling box's edge the nearest caret can sit just past it; step to one that shows.
    if let visible = surface.visibleRect,
       let first = surface.layout.caretRect(at: caret, affinity: .upstream)
    {
      let string = surface.layout.text.attributedString.string as NSString
      // Past the trailing edge, step back; past the leading edge, forward.
      let step = first.midX + surface.origin.x > visible.midX ? -1 : 1
      var steps = 0
      while caretRect(at: starts[index] + caret, affinity: .upstream) == nil, steps < 64 {
        let next = step > 0
          ? (caret < string.length ? NSMaxRange(string.rangeOfComposedCharacterSequence(at: caret)) : caret)
          : (caret > 0 ? string.rangeOfComposedCharacterSequence(at: caret - 1).location : caret)
        guard next != caret else { break }
        caret = next
        steps += 1
      }
    }
    return starts[index] + caret
  }

  /// The word a press at `point` selects, as a flat range; nil when no text is within `padding`.
  public func wordRange(at point: CGPoint, padding: CGFloat) -> NSRange? {
    guard let index = surface(at: point, padding: padding) else { return nil }
    let surface = surfaces[index]
    let local = surface.local(point)
    var word = surface.layout.wordRange(at: local)
    guard word.length > 0 else { return nil }
    // A press on the space between words takes the nearer word, as text views do.
    if Self.isWhitespace(surface.layout.string(in: word)), let line = surface.layout.rects(for: word).first {
      let layout = surface.layout
      let neighbors = [
        word.location > 0 ? layout.wordRange(at: word.location - 1) : nil,
        NSMaxRange(word) < layout.length ? layout.wordRange(at: NSMaxRange(word)) : nil,
      ].compactMap { $0 }.filter { !Self.isWhitespace(layout.string(in: $0)) }
      // Sideways distance on the space's own line; the press may sit a little above or below it.
      func distance(_ range: NSRange) -> CGFloat {
        layout.rects(for: range)
          .filter { abs($0.midY - line.midY) < 1 }
          .map { max($0.minX - local.x, local.x - $0.maxX, 0) }
          .min() ?? .greatestFiniteMagnitude
      }
      if let nearest = neighbors.min(by: { distance($0) < distance($1) }), distance(nearest) < 44 {
        word = nearest
      }
    }
    return NSRange(location: starts[index] + word.location, length: word.length)
  }

  private static func isWhitespace(_ string: String) -> Bool {
    string.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
  }

  // MARK: - Ranges

  /// The flat range between two carets, widened to whole grapheme clusters.
  public func selectionRange(from anchor: Int, to focus: Int) -> NSRange {
    let lower = min(max(min(anchor, focus), 0), length)
    let upper = min(max(max(anchor, focus), 0), length)
    guard upper > lower,
          let start = location(of: lower, affinity: .downstream),
          let end = location(of: upper, affinity: .upstream)
    else { return NSRange(location: lower, length: 0) }
    let startString = surfaces[start.surface].layout.text.attributedString.string as NSString
    let endString = surfaces[end.surface].layout.text.attributedString.string as NSString
    let from = start.offset < startString.length
      ? startString.rangeOfComposedCharacterSequence(at: start.offset).location
      : start.offset
    let to = end.offset > 0 ? NSMaxRange(endString.rangeOfComposedCharacterSequence(at: end.offset - 1)) : 0
    let location = starts[start.surface] + from
    return NSRange(location: location, length: max(0, starts[end.surface] + to - location))
  }

  /// Each surface's own part of a flat `range`, nil for surfaces outside it.
  public func surfaceRanges(for range: NSRange) -> [NSRange?] {
    surfaces.indices.map { index in
      let start = starts[index]
      let end = start + surfaces[index].layout.length
      let lower = max(range.location, start)
      let upper = min(NSMaxRange(range), end)
      if upper > lower { return NSRange(location: lower - start, length: upper - lower) }
      // An empty surface inside the selection still holds its place in the document.
      if start == end, start > range.location, start < NSMaxRange(range) { return NSRange(location: 0, length: 0) }
      return nil
    }
  }

  /// The selected characters with nothing between surfaces; copy goes through the host's
  /// document, which knows the separators.
  public func string(in range: NSRange) -> String {
    zip(surfaces, surfaceRanges(for: range)).compactMap { surface, local in
      local.map { surface.layout.string(in: $0) }
    }.joined()
  }

  // MARK: - Geometry

  /// A caret at flat `index`, or nil when it falls outside its surface's visible part.
  public func caretRect(at index: Int, affinity: TextCaretAffinity) -> CGRect? {
    guard let location = location(of: index, affinity: affinity) else { return nil }
    let surface = surfaces[location.surface]
    guard let caret = surface.layout.caretRect(at: location.offset, affinity: affinity) else { return nil }
    let rect = caret.offsetBy(dx: surface.origin.x, dy: surface.origin.y)
    if let visible = surface.visibleRect, rect.midX < visible.minX - 1 || rect.midX > visible.maxX + 1 {
      return nil
    }
    return rect
  }

  /// Highlight rects for a flat `range`, cut to what shows. Within a surface, gaps between
  /// lines up to `lineGap` close, so a selection over wrapped lines reads as one shape.
  public func highlightRects(for range: NSRange, lineGap: CGFloat = 4) -> [CGRect] {
    var result: [CGRect] = []
    for (surface, local) in zip(surfaces, surfaceRanges(for: range)) {
      guard let local, local.length > 0 else { continue }
      var rects = surface.layout.rects(for: local).map { $0.offsetBy(dx: surface.origin.x, dy: surface.origin.y) }
      if rects.count > 1 {
        for index in 0 ..< rects.count - 1 {
          let gap = rects[index + 1].minY - rects[index].maxY
          guard gap > 0, gap <= lineGap else { continue }
          rects[index].size.height += gap / 2
          rects[index + 1].origin.y -= gap / 2
          rects[index + 1].size.height += gap / 2
        }
      }
      for rect in rects {
        guard let visible = surface.visibleRect else {
          result.append(rect)
          continue
        }
        let clipped = rect.intersection(visible)
        if !clipped.isNull, !clipped.isEmpty { result.append(clipped) }
      }
    }
    return result
  }

  private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
    let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
    return hypot(dx, dy)
  }
}
