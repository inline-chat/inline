import Foundation
import InlineProtocol
import Testing
@testable import TextProcessing
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Suite("Inline formula presentation")
@MainActor
struct RichTextMathInlineTests {
  private func span(_ range: NSRange) -> BlockText {
    .with { $0.offset = Int64(range.location); $0.length = Int64(range.length) }
  }

  private func marked(_ source: String, formulas: [String]) -> NSMutableAttributedString {
    let value = NSMutableAttributedString(string: source, attributes: [
      .font: PlatformFont.systemFont(ofSize: 17), .foregroundColor: PlatformColor.black,
    ])
    var start = 0
    for formula in formulas {
      let range = (source as NSString).range(of: formula, range: NSRange(location: start, length: value.length - start))
      value.addAttribute(.richTextMath, value: NSValue(range: range), range: range)
      start = NSMaxRange(range)
    }
    return value
  }

  private func snapshot(_ text: NSAttributedString, content: BlockContent? = nil) -> RichTextMath.Snapshot {
    let content = content ?? .with { $0.blocks = [.with { $0.paragraph = span(NSRange(location: 0, length: text.length)) }] }
    return RichTextMath.snapshot(content: content, text: text, fontSize: 17) { range, _ in
      text.attributedSubstring(from: range)
    }
  }

  @Test("Unicode, neighboring semantic entities and styles survive replacement and copy")
  func semanticRanges() async throws {
    let formula = #"\frac{x_1}{y}+\sqrt{z}"#
    let source = "😀 before " + formula + " Maya link"
    let text = marked(source, formulas: [formula])
    let mention = (source as NSString).range(of: "Maya")
    let link = (source as NSString).range(of: "link")
    text.addAttribute(.mentionUserId, value: Int64(42), range: mention)
    text.addAttribute(.link, value: URL(string: "https://inline.chat/test")!, range: link)
    text.addAttributes([.underlineStyle: 1, .strikethroughStyle: 1, .backgroundColor: PlatformColor.yellow],
                       range: NSRange(location: 0, length: text.length))
    let initial = snapshot(text)
    #expect(initial.requests.allSatisfy { !$0.display })
    #expect(await RichTextMath.prepare(initial.requests))
    let ready = initial.refreshed()
    let projected = RichTextMath.projectInline(text, sourceOffset: 0, snapshot: ready, maximumWidth: 300)
    #expect(projected.string == "😀 before \u{fffc} Maya link")
    #expect(Array(text.string.utf16) == Array(source.utf16))
    let mappedMention = (projected.string as NSString).range(of: "Maya")
    let mappedLink = (projected.string as NSString).range(of: "link")
    #expect(projected.attribute(.mentionUserId, at: mappedMention.location, effectiveRange: nil) as? Int64 == 42)
    #expect(projected.attribute(.link, at: mappedLink.location, effectiveRange: nil) as? URL == URL(string: "https://inline.chat/test"))
    let attachmentRange = (projected.string as NSString).range(of: "\u{fffc}")
    #expect(projected.attribute(.underlineStyle, at: attachmentRange.location, effectiveRange: nil) as? Int == 1)
    #expect(projected.attribute(.strikethroughStyle, at: attachmentRange.location, effectiveRange: nil) as? Int == 1)
    #expect(RichTextMath.sourceText(projected, range: attachmentRange) == formula)
    #expect(RichTextMath.sourceText(projected) == source)
    #expect(projected.isEqual(to: RichTextMath.projectInline(text, sourceOffset: 0, snapshot: ready, maximumWidth: 300)))
    let copied = try #require(RichTextMath.sourceAttributedText(projected, range: NSRange(location: 0, length: projected.length)))
    #expect(copied.string == source)
    #expect(copied.attribute(.mentionUserId, at: mention.location, effectiveRange: nil) as? Int64 == 42)
    #expect(copied.attribute(.attachment, at: attachmentRange.location, effectiveRange: nil) == nil)
    let rtf = try copied.data(from: NSRange(location: 0, length: copied.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    #expect(Array(decoded.string.utf16) == Array(source.utf16))
  }

  @Test("A source selection survives readiness and expands partial formulas atomically")
  func selection() async throws {
    let formula = #"\frac{a}{b}"#
    let text = marked("😀 " + formula + " tail", formulas: [formula])
    let initial = snapshot(text)
    _ = await RichTextMath.prepare(initial.requests)
    let projected = RichTextMath.projectInline(text, sourceOffset: 0, snapshot: initial.refreshed())
    let partial = NSRange(location: 5, length: 3)
    let selected = try #require(RichTextMath.remapSelection(partial, from: text, to: projected))
    #expect(selected == NSRange(location: 3, length: 1))
    #expect(RichTextMath.sourceText(projected, range: selected) == formula)
    #expect(RichTextMath.remapSelection(NSRange(location: 5, length: 0), from: text, to: projected) == NSRange(location: 3, length: 0))
    let tail = (text.string as NSString).range(of: "tail")
    let tailSelection = try #require(RichTextMath.remapSelection(tail, from: text, to: projected))
    #expect(RichTextMath.sourceText(projected, range: tailSelection) == "tail")
    #expect(RichTextMath.remapSelection(tailSelection, from: projected, to: text) == tail)
    #expect(RichTextMath.sourceText(projected, range: NSRange(location: 1, length: 1)) == nil)
  }

  @Test("A measured projection stays frozen while another preparation fills the cache")
  func frozenMeasurementProjection() async throws {
    let formula = #"\frac{x_{937162581}}{\sqrt{y+1}}"#
    let text = marked("Before " + formula + " after with wrapping words", formulas: [formula])
    let measured = snapshot(text)
    let before = RichTextMath.projectInline(text, sourceOffset: 0, snapshot: measured, maximumWidth: 180)
    func size(_ value: NSAttributedString) -> CGRect {
      let storage = NSTextStorage(attributedString: value)
      let manager = NSLayoutManager()
      let container = NSTextContainer(size: CGSize(width: 180, height: 1000))
      container.lineFragmentPadding = 0
      manager.addTextContainer(container)
      storage.addLayoutManager(manager)
      manager.ensureLayout(for: container)
      return manager.usedRect(for: container)
    }
    let measuredSize = size(before)
    #expect(await RichTextMath.prepare(measured.requests))
    let ready = measured.refreshed()
    let frozen = RichTextMath.projectInline(text, sourceOffset: 0, snapshot: measured, maximumWidth: 180)
    #expect(frozen.isEqual(to: before))
    #expect(size(frozen) == measuredSize)
    let committed = RichTextMath.projectInline(text, sourceOffset: 0, snapshot: ready, maximumWidth: 180)
    #expect(RichTextMath.containsRenderedMath(committed))
    #expect(RichTextMath.sourceText(committed) == text.string)
    if measured.hasPending {
      #expect(!RichTextMath.containsRenderedMath(frozen))
      #expect(measured.signature != ready.signature)
    }
    let selection = (before.string as NSString).range(of: "after")
    let mapped = try #require(RichTextMath.remapSelection(selection, from: before, to: committed))
    #expect(RichTextMath.sourceText(committed, range: mapped) == "after")
  }

  @Test("Sliced blocks use global source ranges, including adjacent equal formulas")
  func slicedRanges() async {
    let text = marked("prefix x^2x^2 suffix", formulas: ["x^2", "x^2"])
    let range = NSRange(location: 7, length: 6)
    let content = BlockContent.with { $0.blocks = [.with { $0.paragraph = span(range) }] }
    let initial = snapshot(text, content: content)
    #expect(initial.requests.count == 2)
    _ = await RichTextMath.prepare(initial.requests)
    let sliced = text.attributedSubstring(from: range)
    let projected = RichTextMath.projectInline(sliced, sourceOffset: range.location, snapshot: initial.refreshed())
    #expect(projected.string == "\u{fffc}\u{fffc}")
    #expect(RichTextMath.sourceText(projected, range: NSRange(location: 1, length: 1)) == "x^2")
    #expect(RichTextMath.projectInline(sliced, sourceOffset: 0, snapshot: initial.refreshed()).string == sliced.string)
    let rewritten = marked("prefix y^2y^2 suffix", formulas: ["y^2", "y^2"])
    let rewrittenSlice = rewritten.attributedSubstring(from: range)
    #expect(RichTextMath.projectInline(rewrittenSlice, sourceOffset: range.location, snapshot: initial.refreshed()).string == "y^2y^2")
  }

  @Test("Styles drive preparation; code and conflicting or partial source projections stay literal")
  func styleAndSafety() {
    let text = marked("a_1 b_2 c_3 d_4 e_5", formulas: ["a_1", "b_2", "c_3", "d_4", "e_5"])
    let ranges = (0..<5).map { NSRange(location: $0 * 4, length: 3) }
    let content = BlockContent.with { $0.blocks = [
      .with { $0.paragraph = span(ranges[0]) },
      .with { $0.heading = .with { $0.level = 1; $0.text = span(ranges[1]) } },
      .with { $0.footer = span(ranges[2]) },
      .with { $0.table = .with { $0.rows = [.with { $0.cells = [span(ranges[3])] }] } },
      .with { $0.code = .with { $0.text = span(ranges[4]) } },
    ] }
    let prepared = RichTextMath.snapshot(content: content, text: text, fontSize: 17) { range, role in
      let value = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
      let size: CGFloat = switch role { case .heading: 25; case .footer: 13; case .table: 15; default: 17 }
      value.addAttribute(.font, value: PlatformFont.systemFont(ofSize: size), range: NSRange(location: 0, length: value.length))
      return value
    }
    #expect(prepared.requests.map(\.pointSize) == [17, 25, 13, 15])
    let partial = BlockContent.with { $0.blocks = [.with { $0.paragraph = span(NSRange(location: 0, length: 2)) }] }
    #expect(snapshot(text, content: partial).requests.isEmpty)
    let protected = NSMutableAttributedString(attributedString: text)
    protected.addAttribute(.inlineCode, value: true, range: NSRange(location: 0, length: protected.length))
    #expect(snapshot(protected).requests.isEmpty)
    let altered = RichTextMath.snapshot(content: content, text: text, fontSize: 17) { _, _ in NSAttributedString(string: "bad") }
    #expect(altered.requests.isEmpty)
  }

  @Test("Narrow inline layout falls back without clipping; native layout includes formula ascent and descent")
  func layoutBounds() async throws {
    let formula = #"\frac{\sqrt{x+1}}{y_2}"#
    let text = marked("A " + formula + " B", formulas: [formula])
    let initial = snapshot(text)
    _ = await RichTextMath.prepare(initial.requests)
    let ready = initial.refreshed()
    #expect(RichTextMath.projectInline(text, sourceOffset: 0, snapshot: ready, maximumWidth: 1).string == text.string)
    let projected = RichTextMath.projectInline(text, sourceOffset: 0, snapshot: ready, maximumWidth: 250)
    let range = (projected.string as NSString).range(of: "\u{fffc}")
    let attachment = try #require(projected.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment)
    #expect(attachment.bounds.minY < 0)
    #expect(attachment.bounds.width > 1 && attachment.bounds.height > 17)
    let storage = NSTextStorage(attributedString: projected)
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 250, height: 1000))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    #expect(manager.usedRect(for: container).height >= attachment.bounds.height - 1)
    #expect(manager.usedRect(for: container).width >= attachment.bounds.width)
  }

  #if os(macOS)
  @Test("Native TextKit raster fixture for baseline, wrapping, RTL and dark appearance")
  func nativeRasterFixture() async throws {
    let width = 720, height = 360
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    let formulas = [#"\frac{x_1}{y}+\sqrt{z}"#, #"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#]
    let sources = [
      "Before " + formulas[0] + " after. The baseline must stay aligned with ordinary text.",
      "Two formulas " + formulas[0] + " and " + formulas[1] + " wrap without losing their source. Extra words continue onto another line.",
      "متن فارسی " + formulas[0] + " و ادامهٔ متن",
      "Dark appearance: " + formulas[1] + " and a readable descender: gyjp.",
    ]
    var panels: [NSAttributedString] = []
    for (index, source) in sources.enumerated() {
      let matches = formulas.filter { source.contains($0) }
      let text = marked(source, formulas: matches)
      text.addAttribute(.foregroundColor, value: index == 3 ? NSColor.white : NSColor.black,
                        range: NSRange(location: 0, length: text.length))
      if index == 2 {
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = .rightToLeft; paragraph.alignment = .right
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
      }
      let initial = snapshot(text)
      _ = await RichTextMath.prepare(initial.requests)
      panels.append(RichTextMath.projectInline(text, sourceOffset: 0, snapshot: initial.refreshed(), maximumWidth: 680))
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    for (index, panel) in panels.enumerated() {
      context.setFillColor(index == 3 ? NSColor(calibratedWhite: 0.1, alpha: 1).cgColor : NSColor.white.cgColor)
      context.fill(CGRect(x: 0, y: index * 90, width: width, height: 90))
      let storage = NSTextStorage(attributedString: panel)
      let manager = NSLayoutManager()
      let container = NSTextContainer(size: CGSize(width: 680, height: 80))
      container.lineFragmentPadding = 0
      manager.addTextContainer(container); storage.addLayoutManager(manager)
      manager.ensureLayout(for: container)
      if index == 1 { #expect(manager.usedRect(for: container).height > 40) }
      let glyphs = manager.glyphRange(for: container)
      manager.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: 20, y: index * 90 + 15))
      manager.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: 20, y: index * 90 + 15))
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/inline-rich-text-v2-inline-math-native.png"))
    #expect(png.count > 1000)
  }
  #endif
}
