import CoreGraphics
import Foundation

/// The animated glyphs for "sending photo / video / file".
///
/// Every frame is a pure function of time, drawn with Core Graphics in a 16×12pt,
/// y-down design space. SwiftUI (`Canvas`), AppKit views and offline frame renders
/// share this one drawing, so the glyph looks identical everywhere and two
/// indicators on screen stay in phase.
///
/// Each glyph tells a small story that ends in a send, and every loop closes on
/// exactly the frame it starts from.
public enum SendingActivityGlyph {
  public enum Kind: String, CaseIterable, Sendable {
    case photo
    case video
    case file
  }

  public static let designSize = CGSize(width: 16, height: 12)

  /// One full loop, in seconds.
  public static func cycleDuration(for kind: Kind) -> TimeInterval {
    switch kind {
    case .photo: 2.2
    case .video: 1.6
    case .file: 2.4
    }
  }

  /// A frame that reads well on its own, for Reduce Motion and static previews.
  public static func restingTime(for kind: Kind) -> TimeInterval {
    switch kind {
    case .photo: 0.3 * cycleDuration(for: .photo)
    case .video: 0.3 * cycleDuration(for: .video)
    case .file: 0.62 * cycleDuration(for: .file)
    }
  }

  /// Draws `kind` at `time` into `rect` (y-down), scaled to fit and centered.
  public static func draw(
    _ kind: Kind,
    in context: CGContext,
    rect: CGRect,
    time: TimeInterval,
    color: CGColor
  ) {
    let scale = min(rect.width / designSize.width, rect.height / designSize.height)
    guard scale > 0, scale.isFinite else { return }
    let phase = Self.phase(time, period: cycleDuration(for: kind))

    context.saveGState()
    context.translateBy(
      x: rect.midX - designSize.width * scale / 2,
      y: rect.midY - designSize.height * scale / 2
    )
    context.scaleBy(x: scale, y: scale)
    context.clip(to: CGRect(origin: .zero, size: designSize))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let pen = Pen(context: context, color: color)
    switch kind {
    case .photo: drawPhoto(pen, phase: phase)
    case .video: drawVideo(pen, phase: phase)
    case .file: drawFile(pen, phase: phase)
    }
    context.restoreGState()
  }

  // MARK: - Photo

  // Snap and send, continuously: each picture slides up into the frame (the far peak
  // a beat behind the near one, the sun rising last), a glint wipes the print, then the
  // frame crouches and tosses it out the top while the next picture is already sliding
  // in behind it. The frame is never empty.
  private static func drawPhoto(_ pen: Pen, phase p: Double) {
    let ctx = pen.context
    // Resting edges sit on whole pixels at 2x, so the outline is crisp on a Mac.
    let frame = CGRect(x: 1.5, y: 1.5, width: 13, height: 9)
    let inner = frame.insetBy(dx: 1.5, dy: 1.5)
    let entryStart = 0.78
    let entrySpan = 0.42

    // Squash on the crouch, then stretch past rest as it throws, and settle.
    let crouch = easeOut(segment(p, 0.66, 0.74))
    let release = segment(p, 0.74, 1.0)
    let squash = 0.075 * (crouch * (1 - release) - (release > 0 ? 0.9 * impulse(release) : 0))
    ctx.saveGState()
    scale(ctx, x: 1 + 0.65 * squash, y: 1 - squash, about: CGPoint(x: frame.midX, y: frame.maxY))

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
    ctx.clip()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // The picture on show came in at the end of the last loop and leaves on the toss.
    let toss = easeIn(segment(p, 0.74, 0.9))
    if toss < 1 {
      // It fades as it rises, so the leaving picture never reads as a heavy bar.
      drawPicture(
        pen,
        in: inner,
        entry: segment(p + 1 - entryStart, 0, entrySpan),
        lift: (inner.height + 2.5) * toss,
        alpha: 1 - 0.6 * toss
      )
    }
    if p > entryStart {
      drawPicture(pen, in: inner, entry: segment(p - entryStart, 0, entrySpan), lift: 0, alpha: 1)
    }

    // Glint: a wide and a thin streak of light wipe across the print, fading in and out.
    let glint = segment(p, 0.36, 0.58)
    if glint > 0, glint < 1 {
      let x = lerp(inner.minX - 3, inner.maxX + 5, easeInOut(glint))
      let strength = 0.9 * sin(Double.pi * glint)
      ctx.setBlendMode(.destinationOut)
      for (offset, width) in [(CGFloat(0), CGFloat(1.5)), (CGFloat(2.2), CGFloat(0.6))] {
        let left = x + offset
        pen.fill(polygon([
          CGPoint(x: left, y: inner.minY - 1),
          CGPoint(x: left + width, y: inner.minY - 1),
          CGPoint(x: left + width - 4, y: inner.maxY + 1),
          CGPoint(x: left - 4, y: inner.maxY + 1),
        ]), alpha: strength)
      }
      ctx.setBlendMode(.normal)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    pen.stroke(CGPath(roundedRect: frame, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil), width: 1.0)
    ctx.restoreGState()
  }

  /// One picture, `entry` 0…1 through its slide-in, lifted out by `lift`.
  private static func drawPicture(_ pen: Pen, in inner: CGRect, entry t: Double, lift: CGFloat, alpha: Double) {
    let card = spring(segment(t, 0, 0.62), damping: 7)
    let near = spring(segment(t, 0.06, 0.7), damping: 7)
    let far = spring(segment(t, 0.18, 0.84), damping: 7)
    let sun = spring(segment(t, 0.36, 1.0), damping: 6)
    let drop = inner.height + 1

    pen.fill(
      CGPath(rect: inner.offsetBy(dx: 0, dy: drop * CGFloat(1 - card) - lift), transform: nil),
      alpha: 0.16 * alpha
    )
    // The sun sits behind the hills, so it rises from behind them.
    if sun > 0 {
      let rest = CGPoint(x: inner.minX + 2.0, y: inner.minY + 1.75)
      let start = CGPoint(x: inner.minX + 3.1, y: inner.maxY + 0.8)
      let center = CGPoint(x: lerp(start.x, rest.x, sun), y: lerp(start.y, rest.y, sun) - lift)
      pen.fill(circle(center, radius: 1.25), alpha: alpha)
    }
    pen.fill(farPeak(in: inner).offsetBy(0, drop * CGFloat(1 - far) - lift), alpha: alpha)
    pen.fill(nearPeak(in: inner).offsetBy(0, drop * CGFloat(1 - near) - lift), alpha: alpha)
  }

  private static func nearPeak(in r: CGRect) -> CGPath {
    polygon([
      CGPoint(x: r.minX - 0.5, y: r.maxY + 0.5),
      CGPoint(x: r.minX - 0.5, y: r.maxY - r.height * 0.14),
      CGPoint(x: r.minX + r.width * 0.30, y: r.maxY - r.height * 0.46),
      CGPoint(x: r.minX + r.width * 0.64, y: r.maxY + 0.5),
    ])
  }

  private static func farPeak(in r: CGRect) -> CGPath {
    polygon([
      CGPoint(x: r.minX + r.width * 0.30, y: r.maxY + 0.5),
      CGPoint(x: r.minX + r.width * 0.44, y: r.maxY - r.height * 0.30),
      CGPoint(x: r.minX + r.width * 0.70, y: r.maxY - r.height * 0.84),
      CGPoint(x: r.maxX + 0.5, y: r.maxY - r.height * 0.30),
      CGPoint(x: r.maxX + 0.5, y: r.maxY + 0.5),
    ])
  }

  // MARK: - Video

  // Film runs steadily past: a light outlined strip with one row of sprocket holes
  // along each edge, gliding left and fading in and out at the ends, while the play
  // mark swells gently once per sprocket. Sparse enough to read at status-line size.
  private static func drawVideo(_ pen: Pen, phase p: Double) {
    // Outline edges sit on whole pixels at 2x; a 1pt line matches the photo frame.
    let strip = CGRect(x: 1.5, y: 1.0, width: 13, height: 10)
    let pitch: CGFloat = 4.0
    let sprockets = 2.0
    let travel = CGFloat(p * sprockets).truncatingRemainder(dividingBy: 1) * pitch
    let hole = CGSize(width: 2.0, height: 1.0)
    let lane = (minX: strip.minX + 1.25, maxX: strip.maxX - 1.25)

    for y: CGFloat in [2.5, 8.5] {
      var x = lane.minX - pitch - travel + pitch / 2
      while x < lane.maxX + pitch {
        let center = x + hole.width / 2
        // Holes ease in at the right and out at the left instead of being cut off.
        let fade = smoothstep(Double((center - lane.minX) / 1.75)) * smoothstep(Double((lane.maxX - center) / 1.75))
        pen.fill(
          CGPath(roundedRect: CGRect(x: x, y: y, width: hole.width, height: hole.height), cornerWidth: 0.4, cornerHeight: 0.4, transform: nil),
          alpha: fade
        )
        x += pitch
      }
    }
    pen.stroke(CGPath(roundedRect: strip, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil), width: 1.0)

    // A soft swell per sprocket. It grows from its left edge, which stays on a whole
    // pixel, so the mark never shimmers a half-lit column at 2x.
    let beat = 0.5 - 0.5 * cos(p * sprockets * 2 * Double.pi)
    let height = 3.2 + 0.4 * beat
    let stroke: CGFloat = 0.7
    let left = 6.5 + stroke / 2
    let triangle = polygon([
      CGPoint(x: left, y: strip.midY - height / 2),
      CGPoint(x: left + height * 0.9, y: strip.midY),
      CGPoint(x: left, y: strip.midY + height / 2),
    ])
    pen.fill(triangle, alpha: 1)
    pen.stroke(triangle, width: stroke)
  }

  // MARK: - File

  // A sheet fills in line by line: a title, then two lines, each written by a small
  // nib riding the tip. The corner flap shades in as it finishes, then the sheet hops
  // as it sends and the lines drain out to the right, leaving it ready for the next.
  private static func drawFile(_ pen: Pen, phase p: Double) {
    let ctx = pen.context
    // Hop on the send: a small crouch, a lift, and a soft landing.
    let crouch = easeOut(segment(p, 0.66, 0.74)) * (1 - easeOut(segment(p, 0.74, 0.79)))
    let hop = sin(Double.pi * segment(p, 0.74, 0.91))
    let land = impulse(segment(p, 0.91, 1.0))
    let squash = 0.06 * crouch + 0.05 * land

    ctx.saveGState()
    ctx.translateBy(x: 0, y: -1.0 * CGFloat(hop))
    // Squash about the bottom edge, which stays on a whole pixel at rest.
    scale(ctx, x: 1 + 0.6 * squash, y: 1 - squash, about: CGPoint(x: 7.25, y: 11.0))

    // Edges on whole pixels at 2x; a 1pt outline matches the weight of the status text.
    // The sheet leaves 1pt of headroom so the hop never clips its top edge.
    let sheet = CGRect(x: 3.0, y: 1.5, width: 8.5, height: 9.5)
    let fold: CGFloat = 3.5
    let r: CGFloat = 1.5

    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: sheet.minX + r, y: sheet.minY))
    outline.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.minY))
    outline.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY + fold))
    outline.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - r))
    outline.addArc(tangent1End: CGPoint(x: sheet.maxX, y: sheet.maxY), tangent2End: CGPoint(x: sheet.maxX - r, y: sheet.maxY), radius: r)
    outline.addLine(to: CGPoint(x: sheet.minX + r, y: sheet.maxY))
    outline.addArc(tangent1End: CGPoint(x: sheet.minX, y: sheet.maxY), tangent2End: CGPoint(x: sheet.minX, y: sheet.maxY - r), radius: r)
    outline.addLine(to: CGPoint(x: sheet.minX, y: sheet.minY + r))
    outline.addArc(tangent1End: CGPoint(x: sheet.minX, y: sheet.minY), tangent2End: CGPoint(x: sheet.minX + r, y: sheet.minY), radius: r)
    outline.closeSubpath()

    let flap = polygon([
      CGPoint(x: sheet.maxX - fold, y: sheet.minY),
      CGPoint(x: sheet.maxX - fold, y: sheet.minY + fold - 0.4),
      CGPoint(x: sheet.maxX - fold + 0.4, y: sheet.minY + fold),
      CGPoint(x: sheet.maxX, y: sheet.minY + fold),
    ])

    // A title line, then two body lines, written one after another.
    // Centers on the 2x grid: a 1.5pt title on a quarter point, 1pt lines on a half.
    let rows: [(y: CGFloat, width: CGFloat, weight: CGFloat)] = [(3.25, 2.75, 1.5), (5.5, 5.0, 1.0), (7.5, 3.75, 1.0)]
    for (index, row) in rows.enumerated() {
      let start = CGPoint(x: sheet.minX + 1.75, y: sheet.minY + row.y)
      pen.strokeLine(from: start, to: CGPoint(x: start.x + row.width, y: start.y), width: row.weight, alpha: 0.3)
      let i = Double(index)
      let written = easeInOut(segment(p, 0.04 + i * 0.15, 0.24 + i * 0.15))
      // On the send the ink drains out to the right, top line first.
      let drained = easeIn(segment(p, 0.74 + i * 0.05, 0.88 + i * 0.05))
      let head = start.x + row.width * CGFloat(written)
      let tail = start.x + row.width * CGFloat(drained)
      let length = head - tail
      guard length > 0.001 else { continue }
      // A round cap is a full dot even at zero length, so ease the ink in and out.
      let ink = smoothstep(Double(length / 0.5))
      pen.strokeLine(from: CGPoint(x: tail, y: start.y), to: CGPoint(x: head, y: start.y), width: row.weight, alpha: ink)
      // The nib: a slightly heavier tip while the line is being written.
      let nib = sin(Double.pi * written)
      if nib > 0.02, drained == 0 {
        pen.fill(circle(CGPoint(x: head, y: start.y), radius: row.weight / 2 + 0.2 * CGFloat(nib)), alpha: nib)
      }
    }

    // The flap shades in as the last line lands and clears after the send.
    let flapShade = 0.3 + 0.45 * smoothstep(segment(p, 0.5, 0.6)) * (1 - smoothstep(segment(p, 0.84, 1.0)))
    pen.fill(flap, alpha: flapShade)
    pen.stroke(outline, width: 1.0)
    pen.stroke(flap, width: 1.0)
    ctx.restoreGState()
  }

  // MARK: - Timing

  static func phase(_ time: TimeInterval, period: TimeInterval) -> Double {
    let wrapped = (time / max(period, 0.01)).truncatingRemainder(dividingBy: 1)
    return wrapped >= 0 ? wrapped : wrapped + 1
  }

  static func segment(_ p: Double, _ start: Double, _ end: Double) -> Double {
    min(max((p - start) / (end - start), 0), 1)
  }

  static func easeIn(_ x: Double) -> Double { x * x * x }
  static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
  static func easeInOut(_ x: Double) -> Double {
    x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
  }

  static func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
  }

  /// 0 → 1 with one soft overshoot; exactly 1 at x = 1, so springs close their loops.
  static func spring(_ x: Double, damping: Double) -> Double {
    guard x > 0 else { return 0 }
    guard x < 1 else { return 1 }
    return 1 - exp(-damping * x) * cos(2.5 * Double.pi * x)
  }

  /// A kick that peaks early and rings out to exactly 0 at both ends.
  static func impulse(_ x: Double) -> Double {
    guard x > 0, x < 1 else { return 0 }
    return 1.9 * exp(-3.2 * x) * sin(2 * Double.pi * x)
  }

  // MARK: - Geometry

  private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
  }

  private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
  }

  private static func circle(_ center: CGPoint, radius: CGFloat) -> CGPath {
    CGPath(
      ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
      transform: nil
    )
  }

  private static func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
  }

  private static func scale(_ ctx: CGContext, x: Double, y: Double, about anchor: CGPoint) {
    ctx.translateBy(x: anchor.x, y: anchor.y)
    ctx.scaleBy(x: CGFloat(x), y: CGFloat(y))
    ctx.translateBy(x: -anchor.x, y: -anchor.y)
  }

  // MARK: - Drawing

  private struct Pen {
    let context: CGContext
    let color: CGColor

    func fill(_ path: CGPath, alpha: Double) {
      guard alpha > 0.001 else { return }
      context.setFillColor(color.copy(alpha: color.alpha * alpha) ?? color)
      context.addPath(path)
      context.fillPath()
    }

    func stroke(_ path: CGPath, width: CGFloat, alpha: Double = 1) {
      guard alpha > 0.001 else { return }
      context.setStrokeColor(color.copy(alpha: color.alpha * alpha) ?? color)
      context.setLineWidth(width)
      context.addPath(path)
      context.strokePath()
    }

    func strokeLine(from: CGPoint, to: CGPoint, width: CGFloat, alpha: Double) {
      let path = CGMutablePath()
      path.move(to: from)
      path.addLine(to: to)
      stroke(path, width: width, alpha: alpha)
    }
  }
}

private extension CGPath {
  func offsetBy(_ dx: CGFloat, _ dy: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: dx, y: dy)
    return copy(using: &transform) ?? self
  }
}
