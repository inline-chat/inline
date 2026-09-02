import CoreGraphics
import CoreText
import Foundation
import ImageIO
import InlineMath
import UniformTypeIdentifiers

/// Local raster/performance evidence. No app UI, network, or message data.
@main
struct MathRenderProbe {
  static func main() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    _ = try await MathRenderer.shared.render(request("x^2")).get()
    let firstMilliseconds = milliseconds(start.duration(to: clock.now))
    let formulas = [
      "x^2+y^2=z^2", #"\frac{a+b}{c+d}"#, #"\sqrt{x^2+\frac{1}{y}}"#,
      #"\sum_{n=1}^{\infty}\frac{1}{n^2}=\frac{\pi^2}{6}"#,
      #"\int_0^1 x\,dx=\frac{1}{2}"#,
      #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#,
      #"\left\{\begin{matrix}x&x>0\\-x&x<0\end{matrix}\right."#,
      #"\overline{x}+\underline{y}+\widehat{ABC}"#,
      #"x+\textcolor{#ff5555}{\frac{a}{b}}"#,
      #"\colorbox{#4080ff}{x}+\color{#ff5555}{y}"#,
    ]
    var cold: [Double] = [], cached: [Double] = []
    for index in 0..<100 {
      let item = request(formulas[index % formulas.count] + "+\(index)")
      let begin = clock.now
      _ = try await MathRenderer.shared.render(item).get()
      cold.append(milliseconds(begin.duration(to: clock.now)))
      let cachedBegin = clock.now
      _ = try await MathRenderer.shared.render(item).get()
      cached.append(milliseconds(cachedBegin.duration(to: clock.now)))
    }
    let destination = URL(fileURLWithPath: "/tmp/inline-rich-text-v2-math-contact-sheet.png")
    try await contactSheet(formulas, destination: destination)
    let report = Report(firstRenderMilliseconds: firstMilliseconds,
                        uncached: Timing(cold), cached: Timing(cached),
                        contactSheet: destination.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
  }

  private static func request(_ tex: String, display: Bool = true,
                              color: MathColor = .init(red: 0.08, green: 0.1, blue: 0.15)) -> MathRenderRequest {
    .init(tex: tex, display: display, pointSize: 24, scale: 2, color: color)
  }

  private static func contactSheet(_ formulas: [String], destination: URL) async throws {
    let width = 960, rowHeight = 126, header = 65
    let height = formulas.count * rowHeight + header
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ProbeError.allocation }
    context.setFillColor(CGColor(gray: 0.96, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    label("InlineMath / inline (left) and display (right) / red line = baseline",
          x: 18, y: CGFloat(height - 35), context: context, light: false, size: 16)
    for (index, tex) in formulas.enumerated() {
      let bottom = CGFloat(height - header - (index + 1) * rowHeight)
      let light = index.isMultiple(of: 2) == false
      context.setFillColor(CGColor(gray: light ? 0.08 : 1, alpha: 1))
      context.fill(CGRect(x: 0, y: bottom, width: CGFloat(width), height: CGFloat(rowHeight)))
      label(tex, x: 18, y: bottom + 105, context: context, light: light, size: 12)
      for column in 0..<2 {
        let image = try await MathRenderer.shared.render(request(
          tex, display: column == 1,
          color: light ? .init(red: 0.95, green: 0.95, blue: 0.98) : .init(red: 0.08, green: 0.1, blue: 0.15)
        )).get()
        let x = CGFloat(column * 480 + 20), baseline = bottom + 42
        context.setStrokeColor(CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 0.45))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: x, y: baseline))
        context.addLine(to: CGPoint(x: x + 440, y: baseline))
        context.strokePath()
        context.draw(image.image, in: CGRect(x: x, y: baseline - image.descent,
                                            width: image.width, height: image.height))
      }
    }
    guard let image = context.makeImage(),
          let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ProbeError.allocation }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw ProbeError.write }
  }

  private static func label(_ text: String, x: CGFloat, y: CGFloat, context: CGContext,
                            light: Bool, size: CGFloat) {
    let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: light ? 0.8 : 0.25, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  private struct Timing: Encodable {
    let samples: Int
    let meanMilliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double

    init(_ values: [Double]) {
      samples = values.count
      meanMilliseconds = values.reduce(0, +) / Double(values.count)
      p95Milliseconds = values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
      maxMilliseconds = values.max() ?? 0
    }
  }

  private struct Report: Encodable {
    let firstRenderMilliseconds: Double
    let uncached: Timing
    let cached: Timing
    let contactSheet: String
  }

  private enum ProbeError: Error { case allocation, write }
}
