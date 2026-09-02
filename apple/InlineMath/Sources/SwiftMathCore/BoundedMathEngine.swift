import Foundation
import CoreGraphics
import CoreText
import CryptoKit

package enum CoreMathFailure: Error, Equatable, Sendable {
  case emptySource, sourceLimit, tokenLimit, invalidParameters, fontUnavailable
  case parse(Int), invalidMetrics, rasterLimit, allocationFailed
}

package struct CoreMathImage: Sendable {
  package let image: CGImage
  package let width: CGFloat
  package let ascent: CGFloat
  package let descent: CGFloat
  package let scale: CGFloat
}

/// Implementation-only, mutable engine. InlineMath's single actor serializes
/// all entry, including upstream parser/factory globals. Never share its trees.
package final class BoundedMathEngine {
  private var fontResources: (CGFont, NSDictionary)?
  private var didLoadFont = false

  package init() {}

  package func render(
    tex: String, display: Bool, pointSize: Double, scale: Double, color: CGColor
  ) -> Result<CoreMathImage, CoreMathFailure> {
    guard pointSize.isFinite, (4...96).contains(pointSize), scale.isFinite, (1...4).contains(scale)
    else { return .failure(.invalidParameters) }
    if let error = Self.preflight(tex, display: display) { return .failure(error) }
    guard let font = makeFont(size: pointSize) else { return .failure(.fontUnavailable) }
    var parseError: NSError?
    guard let list = MTMathListBuilder.build(fromString: tex, error: &parseError), parseError == nil else {
      return .failure(.parse(parseError?.code ?? 0))
    }
    let line: MTMathListDisplay
    do {
      guard let result = try MTTypesetter.createLineForMathList(list, font: font, style: display ? .display : .text)
      else { return .failure(.invalidMetrics) }
      line = result
    } catch MTTypesettingFailure.resourceLimit {
      return .failure(.rasterLimit)
    } catch {
      return .failure(.invalidMetrics)
    }
    line.textColor = MTColor(cgColor: color)

    // Include leading negative spacing and direct glyph ink overhang, rather
    // than clipping to the typesetter's advance width alone.
    var bounds = CGRect(x: 0, y: -line.descent, width: line.width, height: line.ascent + line.descent)
    for item in line.subDisplays {
      let rect: CGRect
      if let glyphLine = item as? MTCTLineDisplay {
        rect = CTLineGetBoundsWithOptions(glyphLine.line, .useGlyphPathBounds)
          .offsetBy(dx: item.position.x, dy: item.position.y)
      } else {
        rect = item.displayBounds()
      }
      guard Self.valid(rect) else { return .failure(.invalidMetrics) }
      bounds = bounds.union(rect)
    }
    guard Self.valid(bounds), line.width >= 0, line.ascent >= 0, line.descent >= 0,
          line.width.isFinite, line.ascent.isFinite, line.descent.isFinite
    else { return .failure(.invalidMetrics) }
    // Padding covers antialiasing and nested italic glyph overhang. It is part
    // of returned metrics, so baseline placement remains exact for the bitmap.
    let padding = max(1 / scale, pointSize * 0.15)
    bounds = bounds.insetBy(dx: -padding, dy: -padding)
    let pixelWidth = ceil(bounds.width * scale)
    let pixelHeight = ceil(bounds.height * scale)
    guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0,
          pixelWidth <= 4096, pixelHeight <= 4096, pixelWidth * pixelHeight <= 4_000_000
    else { return .failure(.rasterLimit) }
    let width = Int(pixelWidth), height = Int(pixelHeight)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return .failure(.allocationFailed) }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    context.textMatrix = .identity
    line.draw(context)
    guard let image = context.makeImage() else { return .failure(.allocationFailed) }
    let descent = -bounds.minY
    return .success(CoreMathImage(image: image, width: CGFloat(width) / scale,
                                  ascent: CGFloat(height) / scale - descent, descent: descent, scale: scale))
  }

  private static func valid(_ rect: CGRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width >= 0 && rect.height >= 0
  }

  private static func preflight(_ tex: String, display: Bool) -> CoreMathFailure? {
    let limit = display ? 8192 : 2048
    guard tex.utf8.prefix(limit + 1).count <= limit, tex.utf16.prefix(limit + 1).count <= limit
    else { return .sourceLimit }
    guard !tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptySource }
    let scalars = Array(tex.unicodeScalars)
    var index = 0, tokens = 0
    while index < scalars.count {
      let scalar = scalars[index]
      index += 1
      if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
      tokens += 1
      if tokens > 2048 { return .tokenLimit }
      if scalar == "\\", index < scalars.count {
        if isCommandLetter(scalars[index]) {
          while index < scalars.count, isCommandLetter(scalars[index]) { index += 1 }
        } else { index += 1 }
      }
    }
    return nil
  }

  private static func isCommandLetter(_ scalar: Unicode.Scalar) -> Bool {
    (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
  }

  private func makeFont(size: CGFloat) -> MTFont? {
    if !didLoadFont {
      didLoadFont = true
      guard let bundleURL = Bundle.module.url(forResource: "mathFonts", withExtension: "bundle"),
            let bundle = Bundle(url: bundleURL),
            let fontURL = bundle.url(forResource: "latinmodern-math", withExtension: "otf"),
            let tableURL = bundle.url(forResource: "latinmodern-math", withExtension: "plist"),
            let fontData = try? Data(contentsOf: fontURL), let tableData = try? Data(contentsOf: tableURL),
            Self.digest(fontData) == "6075562b771f8b82f0c179e363389684f2dd09de30038269e2628e504bd7be0f",
            Self.digest(tableData) == "201e6a483783415f335328f2d02b356fe55cd478eb0cd052898236589c8cb946",
            let provider = CGDataProvider(data: fontData as CFData), let cgFont = CGFont(provider),
            let table = (try? PropertyListSerialization.propertyList(from: tableData, format: nil)) as? NSDictionary,
            table["version"] as? String == "1.3"
      else { return nil }
      fontResources = (cgFont, table)
    }
    guard let (cgFont, table) = fontResources else { return nil }
    let font = MTFont()
    font.defaultCGFont = cgFont
    font.ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
    guard CTFontGetUnitsPerEm(font.ctFont) > 0 else { return nil }
    font.rawMathTable = table
    font.mathTable = MTFontMathTable(withFont: font, mathTable: table)
    return font
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
