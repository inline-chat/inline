import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import InlineMessageLayout

/// Draws planned layouts into PNGs on the Mac, so geometry can be reviewed without a device.
/// Off by default; run with `INLINE_LAYOUT_PREVIEW_DIR=/some/dir swift test --filter layoutPreview`.
/// Bubbles here are a simple stand-in for the app's tail shape; text uses the same Core Text
/// drawing as the app's `MessageTextView`.
@Suite("Layout preview")
struct LayoutPreviewRenderer {
  @Test("Render previews", .enabled(if: ProcessInfo.processInfo.environment["INLINE_LAYOUT_PREVIEW_DIR"] != nil))
  func layoutPreview() throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INLINE_LAYOUT_PREVIEW_DIR"]!)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let gold = "Sounds good, see you tomorrow"
    let reactions = (0 ..< 6).map {
      MessageLayoutInput.Reaction(id: ["🎉", "❤️", "😂", "👀", "🔥", "✅"][$0], size: CGSize(width: 44, height: 32))
    }
    var named = Fixtures.message("Thread messages show the sender above the first bubble.", tail: BubbleTailSide.none, avatar: .reserved)
    named.name = Fixtures.text("Ava", font: Fixtures.font(13))
    let grouped = Fixtures.message("The bubble below lines up with this one.", tail: .leading, avatar: .visible)

    try render(
      "gold-standard",
      [
        Fixtures.message(gold, reactions: []),
        Fixtures.message(gold, reactions: [MessageLayoutInput.Reaction(id: "👍", size: CGSize(width: 44, height: 32))]),
      ],
      to: directory
    )
    try render(
      "catalog",
      [
        Fixtures.message("On my way", outgoing: true),
        Fixtures.message(
          "On my way, but the train is running a little late. I'll message again when I'm close, probably twenty minutes.",
          outgoing: true
        ),
        named,
        grouped,
        Fixtures.message("سلام! این پیام فارسی است و باید از راست به چپ نمایش داده شود، حتی وقتی چند خط می‌شود."),
        Fixtures.message("😀", outgoing: true, emoji: true),
        Fixtures.message("Many reactions wrap onto more rows inside the bubble.", outgoing: true, reactions: reactions),
      ],
      to: directory
    )
  }

  private func render(_ name: String, _ inputs: [MessageLayoutInput], to directory: URL) throws {
    let layouts = inputs.map { MessageLayoutPlanner.layout($0) }
    let width = inputs.first?.rowWidth ?? 390
    let gap: CGFloat = 12
    let height = layouts.reduce(gap) { $0 + $1.size.height + gap }
    let scale: CGFloat = 3
    let context = try #require(CGContext(
      data: nil,
      width: Int(width * scale),
      height: Int(height * scale),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    // Work in y-down points, like UIKit.
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    var y = gap
    for (input, layout) in zip(inputs, layouts) {
      context.saveGState()
      context.translateBy(x: 0, y: y)
      draw(layout, input: input, in: context)
      context.restoreGState()
      y += layout.size.height + gap
    }

    let image = try #require(context.makeImage())
    let url = directory.appendingPathComponent("\(name).png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  private func draw(_ layout: MessageLayout, input: MessageLayoutInput, in context: CGContext) {
    let outgoing = input.isOutgoing
    let bubbleColor = outgoing ? CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1) : CGColor(gray: 0.92, alpha: 1)
    if layout.bubble.isVisible {
      context.setFillColor(bubbleColor)
      context.addPath(CGPath(roundedRect: layout.bubble.body, cornerWidth: 18, cornerHeight: 18, transform: nil))
      context.fillPath()
      if layout.bubble.tail != .none {
        let body = layout.bubble.body
        let trailing = layout.bubble.tail == .trailing
        let corner = CGPoint(x: trailing ? body.maxX : body.minX, y: body.maxY)
        let direction: CGFloat = trailing ? 1 : -1
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: corner.x - direction * 18, y: corner.y))
        tail.addLine(to: CGPoint(x: corner.x + direction * 6, y: corner.y))
        tail.addQuadCurve(
          to: CGPoint(x: corner.x, y: corner.y - 14),
          control: CGPoint(x: corner.x + direction * 1, y: corner.y - 3)
        )
        tail.addLine(to: CGPoint(x: corner.x - direction * 18, y: corner.y - 14))
        tail.closeSubpath()
        context.addPath(tail)
        context.fillPath()
      }
    }

    let ink = outgoing && layout.bubble.isVisible ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
    let secondary = outgoing && layout.bubble.isVisible ? CGColor(gray: 1, alpha: 0.7) : CGColor(gray: 0, alpha: 0.5)
    if let text = layout.text, let frame = layout.frame(.text) {
      drawText(text, at: frame.origin, color: ink, in: context)
    }
    if let name = layout.name, let frame = layout.frame(.name) {
      drawText(name, at: frame.origin, color: CGColor(gray: 0, alpha: 0.5), in: context)
    }
    if let frame = layout.frame(.time) {
      drawText(layout.time, at: CGPoint(x: frame.minX, y: frame.minY + (frame.height - layout.time.size.height) / 2), color: secondary, in: context)
      if input.footer.statusSize != nil {
        context.setStrokeColor(secondary)
        context.setLineWidth(1.2)
        let check = CGRect(x: frame.maxX - 10, y: frame.midY - 4, width: 9, height: 7)
        context.move(to: CGPoint(x: check.minX, y: check.midY))
        context.addLine(to: CGPoint(x: check.minX + 3, y: check.maxY))
        context.addLine(to: CGPoint(x: check.maxX, y: check.minY))
        context.strokePath()
      }
    }
    for id in layout.reactionOrder {
      guard let frame = layout.frame(.reaction(id)) else { continue }
      context.setFillColor(outgoing ? CGColor(gray: 1, alpha: 0.22) : CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 0.18))
      context.addPath(CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil))
      context.fillPath()
      let emoji = TextLayouter.layout(Fixtures.text(id, font: Fixtures.font(20)), maximumWidth: 100, grid: Fixtures.grid)
      drawText(emoji, at: CGPoint(x: frame.minX + 7, y: frame.midY - emoji.size.height / 2), color: ink, in: context)
    }
    if let frame = layout.frame(.avatar) {
      context.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1))
      context.fillEllipse(in: frame)
    }
  }

  /// Same transform as `MessageTextView.draw`: per line, move to the baseline and flip up.
  private func drawText(_ layout: TextLayout, at origin: CGPoint, color: CGColor, in context: CGContext) {
    let colored = NSMutableAttributedString(attributedString: layout.text.attributedString)
    colored.addAttribute(
      NSAttributedString.Key(kCTForegroundColorAttributeName as String),
      value: color,
      range: NSRange(location: 0, length: colored.length)
    )
    let recolored = TextLayouter.layout(MessageText(colored), maximumWidth: layout.maximumWidth, grid: Fixtures.grid)
      .aligned(toWidth: layout.size.width)
    context.saveGState()
    context.textMatrix = .identity
    for line in recolored.lines {
      context.saveGState()
      context.translateBy(x: origin.x + line.frame.minX, y: origin.y + line.baseline)
      context.scaleBy(x: 1, y: -1)
      context.textPosition = .zero
      CTLineDraw(line.ctLine, context)
      context.restoreGState()
    }
    context.restoreGState()
  }
}
