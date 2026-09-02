import Foundation
import InlineProtocol
public import InlineMath
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Native render projection helpers. No task, observer, message, or view owner.
public enum RichTextMath {
  public typealias Request = MathRenderRequest
  public typealias Image = MathImage
  public static let maximumFormulas = 64
  public static let maximumImageBytes = 8 * 1024 * 1024

  public enum TextRole {
    case paragraph, heading(Int), footer, disclosure(progress: Bool), table(header: Bool)
  }

  public struct Snapshot: Sendable {
    public let requests: [Request]
    public let signature: Int
    public let hasPending: Bool
    private let inputs: [(NSRange, Request)]
    private let images: [NSRange: Image]

    public func image(for range: NSRange) -> Image? { images[range] }
    func inlineResult(for range: NSRange) -> (Request, Image)? {
      guard let request = inputs.first(where: { $0.0 == range && !$0.1.display })?.1,
            let image = images[range] else { return nil }
      return (request, image)
    }

    /// Re-read readiness without retaining attributed strings or touching UI.
    public func refreshed() -> Snapshot { RichTextMath.snapshot(inputs: inputs) }

    fileprivate init(inputs: [(NSRange, Request)], signature: Int, hasPending: Bool, images: [NSRange: Image]) {
      self.inputs = inputs; self.requests = inputs.map(\.1)
      self.signature = signature; self.hasPending = hasPending; self.images = images
    }
  }

  public static func displayRanges(in content: InlineProtocol.BlockContent, sourceLength: Int) -> [NSRange] {
    var ranges: [NSRange] = [], visited = 0
    func visit(_ blocks: [InlineProtocol.Block], depth: Int) {
      guard depth <= 16 else { return }
      for block in blocks {
        guard ranges.count < maximumFormulas, visited < 2048 else { return }
        visited += 1
        switch block.kind {
        case let .math(text):
          guard text.offset >= 0, text.length > 0, text.offset <= Int64(sourceLength),
                text.length <= Int64(sourceLength) - text.offset else { continue }
          ranges.append(NSRange(location: Int(text.offset), length: Int(text.length)))
        case let .list(list):
          for item in list.items { visit(item.children, depth: depth + 1) }
        case let .quote(quote): visit(quote.children, depth: depth + 1)
        case let .disclosure(disclosure): visit(disclosure.children, depth: depth + 1)
        default: break
        }
      }
    }
    visit(content.blocks, depth: 0)
    return ranges
  }

  /// One immutable availability snapshot for a measurement/render pass.
  /// Reading a miss does not initiate typesetting. The existing native owner
  /// invokes prepare separately and remeasures through its normal update path.
  public static func snapshot(ranges: [NSRange], text: NSAttributedString, fontSize: CGFloat) -> Snapshot {
    snapshot(inputs: ranges.prefix(maximumFormulas).compactMap { range in
      request(text: text, range: range, fontSize: fontSize).map { (range, $0) }
    })
  }

  /// Collect preparation inputs from canonical ranges, using each native
  /// renderer's existing style function. Styling must not alter source bytes.
  public static func snapshot(
    content: InlineProtocol.BlockContent, text: NSAttributedString, fontSize: CGFloat,
    style: (NSRange, TextRole) -> NSAttributedString?
  ) -> Snapshot {
    var inputs: [(NSRange, Request)] = []
    var inlineRanges: [NSRange] = []
    text.enumerateAttribute(.richTextMath, in: NSRange(location: 0, length: text.length)) { value, range, stop in
      guard (value as? NSValue)?.rangeValue == range else { return }
      guard text.attribute(.richTextMathDisplay, at: range.location, effectiveRange: nil) as? Bool != true else { return }
      var protected = false
      for key in [NSAttributedString.Key.inlineCode, .codeBlock] {
        text.enumerateAttribute(key, in: range) { value, _, stop in
          if (value as? Bool) == true { protected = true; stop.pointee = true }
        }
      }
      guard !protected else { return }
      inlineRanges.append(range)
      if inlineRanges.count >= maximumFormulas { stop.pointee = true }
    }
    var visited = 0
    func append(_ span: InlineProtocol.BlockText, role: TextRole?) {
      guard inputs.count < maximumFormulas, span.offset >= 0, span.length > 0,
            span.offset <= Int64(text.length), span.length <= Int64(text.length) - span.offset else { return }
      let range = NSRange(location: Int(span.offset), length: Int(span.length))
      guard let role else {
        if let value = request(text: text, range: range, fontSize: fontSize) { inputs.append((range, value)) }
        return
      }
      let matches = inlineRanges.filter { $0.location >= range.location && NSMaxRange($0) <= NSMaxRange(range) }
      guard !matches.isEmpty, range.length <= 131_072, let styled = style(range, role),
            styled.length == range.length,
            styled.string.utf8.elementsEqual((text.string as NSString).substring(with: range).utf8)
      else { return }
      for sourceRange in matches {
        guard inputs.count < maximumFormulas else { return }
        let localRange = NSRange(location: sourceRange.location - range.location, length: sourceRange.length)
        let size = (styled.attribute(.font, at: localRange.location, effectiveRange: nil) as? PlatformFont)?.pointSize ?? fontSize
        if let value = request(text: styled, range: localRange, fontSize: size, display: false) {
          inputs.append((sourceRange, value))
        }
      }
    }
    func visit(_ blocks: [InlineProtocol.Block], depth: Int) {
      guard depth <= 16 else { return }
      for block in blocks {
        guard visited < 2048, inputs.count < maximumFormulas else { return }
        visited += 1
        switch block.kind {
        case let .math(span): append(span, role: nil)
        case let .paragraph(span): append(span, role: .paragraph)
        case let .heading(heading): append(heading.text, role: .heading(Int(heading.level)))
        case let .footer(span): append(span, role: .footer)
        case let .disclosure(disclosure):
          append(disclosure.summary, role: .disclosure(progress: disclosure.kind == .progress))
          visit(disclosure.children, depth: depth + 1)
        case let .quote(quote): visit(quote.children, depth: depth + 1)
        case let .list(list):
          for item in list.items { visit(item.children, depth: depth + 1) }
        case let .table(table):
          for (index, row) in table.rows.prefix(256).enumerated() {
            for cell in row.cells.prefix(256) {
              guard visited < 2048 else { return }
              visited += 1
              append(cell, role: .table(header: index == 0))
            }
          }
        default: break // Code and media alt text are not inline math surfaces.
        }
      }
    }
    visit(content.blocks, depth: 0)
    // A malformed projection may refer to one range in conflicting roles.
    // Retain source rather than applying arbitrary font/mode semantics.
    var requestsByRange: [NSRange: Request] = [:], conflicts: Set<NSRange> = []
    for (range, request) in inputs {
      if let old = requestsByRange[range], old != request { conflicts.insert(range) }
      requestsByRange[range] = request
    }
    var seen: Set<NSRange> = []
    return snapshot(inputs: inputs.filter { !conflicts.contains($0.0) && seen.insert($0.0).inserted })
  }

  private static func snapshot(inputs: [(NSRange, Request)]) -> Snapshot {
    var images: [NSRange: Image] = [:]
    var hasher = Hasher(), bytes = 0, hasPending = false
    for (range, request) in inputs {
      hasher.combine(range); hasher.combine(request)
      switch MathRenderer.shared.cachedResult(for: request) {
      case let .success(image):
        let cost = image.image.bytesPerRow * image.image.height
        guard cost <= maximumImageBytes - bytes else { hasher.combine(0); continue }
        bytes += cost
        images[range] = image
        hasher.combine(2)
      case .failure: hasher.combine(1)
      case nil: hasher.combine(0); hasPending = true
      }
    }
    return Snapshot(inputs: inputs, signature: hasher.finalize(), hasPending: hasPending, images: images)
  }

  public static func request(text: NSAttributedString, range: NSRange, fontSize: CGFloat, display: Bool = true) -> Request? {
    let limit = display ? 8192 : 2048
    guard fontSize.isFinite, (4...96).contains(fontSize),
          range.location >= 0, range.length > 0, range.length <= limit, range.location <= text.length,
          range.length <= text.length - range.location else { return nil }
    let source = text.string as NSString
    for offset in [range.location, NSMaxRange(range)] where offset > 0 && offset < source.length {
      if (0xD800...0xDBFF).contains(source.character(at: offset - 1)),
         (0xDC00...0xDFFF).contains(source.character(at: offset)) { return nil }
    }
    let color: MathColor
    let scale: Double
    #if os(macOS)
    let native = (text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor ?? .labelColor)
      .usingColorSpace(.sRGB) ?? .black
    color = .init(red: clamp(native.redComponent), green: clamp(native.greenComponent),
                  blue: clamp(native.blueComponent), alpha: clamp(native.alphaComponent))
    scale = 2
    #else
    let native = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor ?? .label
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
    native.getRed(&r, green: &g, blue: &b, alpha: &a)
    color = .init(red: clamp(r), green: clamp(g), blue: clamp(b), alpha: clamp(a))
    scale = 3
    #endif
    let tex = source.substring(with: range)
    guard tex.utf8.prefix(limit + 1).count <= limit else { return nil }
    return Request(tex: tex, display: display,
                   pointSize: Double(fontSize), scale: scale, color: color)
  }

  /// The caller owns cancellation and revision checks. Pixel preparation is
  /// serialized by MathRenderer, never performed by the native layout caller.
  public static func prepare(_ requests: [Request]) async -> Bool {
    var changed = false, bytes = 0
    for request in requests.prefix(maximumFormulas) {
      guard !Task.isCancelled else { return false }
      let cached = MathRenderer.shared.cachedResult(for: request)
      let result = if let cached { cached } else { await MathRenderer.shared.render(request) }
      if case let .success(image) = result {
        let cost = image.image.bytesPerRow * image.image.height
        guard cost <= maximumImageBytes - bytes else { continue }
        bytes += cost
        // Another message may have filled the cache after this caller measured
        // a miss. It still needs the same ready-value geometry commit.
        changed = true
      }
    }
    return changed && !Task.isCancelled
  }

  private static func clamp(_ value: CGFloat) -> Double { Double(min(1, max(0, value))) }
}
