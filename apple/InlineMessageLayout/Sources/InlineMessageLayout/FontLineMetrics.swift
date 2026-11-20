import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// How tall each line is and where its baseline sits.
public enum TextLineHeight: Hashable, Sendable {
  /// Each line is as tall as its own glyphs, fallback fonts included (iOS messages).
  case natural
  /// Each line takes the platform's default line metrics of the fonts set in the attributed
  /// string on that line, the tallest one winning. Fallback fonts (emoji, Devanagari, Thai)
  /// never make a line taller. This is how TextKit lays out `NSTextView`; on macOS it draws the
  /// same pixels as the `NSTextView` it replaces.
  case fontDefault
}

/// A font's default line box: its height and the baseline's distance from the line top.
public struct FontLineMetrics: Hashable, Sendable {
  public var height: CGFloat
  public var baseline: CGFloat

  public init(height: CGFloat, baseline: CGFloat) {
    self.height = height
    self.baseline = baseline
  }

  /// AppKit's rule for modern fonts, from Core Text alone: rounded ascent, descent and
  /// leading, with the baseline one rounded descent above the bottom. Glyphs drawn on that
  /// baseline, color emoji included, land in the same pixels as TextKit 2's at 1x and 2x.
  /// Legacy fonts (Helvetica, Courier, Palatino) get extra height from AppKit that Core Text
  /// doesn't expose, so the Mac app installs AppKit's own heights through
  /// `FontLineMetricsProvider`.
  public static func coreTextDefault(for font: CTFont) -> FontLineMetrics {
    let descent = CTFontGetDescent(font).rounded()
    let height = CTFontGetAscent(font).rounded() + descent + CTFontGetLeading(font).rounded()
    return FontLineMetrics(height: height, baseline: height - descent)
  }
}

/// Where `.fontDefault` layout gets a font's line metrics. Install a platform provider once,
/// before the first layout; layouts already cached keep the metrics they were made with.
public enum FontLineMetricsProvider {
  public typealias Provider = @Sendable (CTFont) -> FontLineMetrics

  /// The closure lives in a class so reads hand back a reference. Reading a bare closure out
  /// of `Mutex` through `withLock { $0 }` re-wraps the stored value in a reabstraction thunk on
  /// every read, so each lookup got slower than the last (a 40-paragraph message took 180 ms).
  private final class Box: Sendable {
    let provider: Provider
    init(_ provider: @escaping Provider) { self.provider = provider }
  }

  private static let current = Mutex(Box { FontLineMetrics.coreTextDefault(for: $0) })

  public static func install(_ provider: @escaping Provider) {
    let box = Box(provider)
    current.withLock { $0 = box }
  }

  static func metrics(for font: CTFont) -> FontLineMetrics {
    let box = current.withLock { $0 }
    return box.provider(font)
  }
}

extension TextLayouter {
  /// The line box for `range` under `.fontDefault`: the tallest of the attributed fonts'
  /// default metrics, with the lowest baseline. Nil when no run on the line names a font.
  static func fontDefaultMetrics(of attributed: NSAttributedString, range: NSRange) -> FontLineMetrics? {
    var above: CGFloat = 0
    var below: CGFloat = 0
    var found = false
    let key = NSAttributedString.Key(kCTFontAttributeName as String)
    attributed.enumerateAttribute(key, in: range, options: []) { value, _, _ in
      guard let value, CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return }
      let metrics = FontLineMetricsProvider.metrics(for: value as! CTFont)
      above = max(above, metrics.baseline)
      below = max(below, metrics.height - metrics.baseline)
      found = true
    }
    return found ? FontLineMetrics(height: above + below, baseline: above) : nil
  }
}
