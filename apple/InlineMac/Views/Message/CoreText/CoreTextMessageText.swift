import AppKit
import CoreText
import InlineKit
import InlineMessageLayout
import InlineProtocol
import Synchronization

/// Inline's Core Text renderer for message text: what it supports, and the text and layout it
/// draws. Behind the "Core Text Message Text" experiment; rich content and anything below that
/// it doesn't draw yet stay on `MessageTextView`.
enum CoreTextMessageText {
  static let defaultsKey = "experimental.coreTextMessageText"

  /// Read from defaults so the size calculator can ask off the main actor.
  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

  /// Whether a message with these entities can be drawn here, decided before its text is built:
  /// code blocks and math are not drawn yet.
  static func supports(entities: MessageEntities?) -> Bool {
    guard let entities else { return true }
    return !entities.entities.contains { $0.type == .pre || $0.type == .math }
  }

  /// Whether this renderer draws `text` the way `MessageTextView` does. Code blocks (their
  /// own backgrounds, padding and spacing) and attachments (inline math) are not drawn yet.
  static func supports(_ text: NSAttributedString) -> Bool {
    guard text.length > 0 else { return true }
    let fullRange = NSRange(location: 0, length: text.length)
    var supported = true
    text.enumerateAttributes(in: fullRange, options: [.longestEffectiveRangeNotRequired]) { attributes, _, stop in
      if attributes[.preCode] != nil || attributes[.codeBlock] != nil || attributes[.attachment] != nil {
        supported = false
        stop.pointee = true
      }
    }
    return supported
  }

  /// Text-to-layout style matching how `MessageTextView` sets text: one base direction for the
  /// whole message, TextKit's line boxes, and the typography's line spacing.
  static func style(for text: NSAttributedString, isRtl: Bool, forcesDirection: Bool = true) -> TextLayoutStyle {
    let paragraph = text.length > 0
      ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
      : nil
    return TextLayoutStyle(
      lineSpacing: paragraph?.lineSpacing ?? 0,
      paragraphSpacing: paragraph?.paragraphSpacing ?? 0,
      lineHeight: .fontDefault,
      baseDirection: forcesDirection ? (isRtl ? .rightToLeft : .leftToRight) : nil
    )
  }

  /// `text` with Core Text's own color keys, resolved for `appearance`, and links colored the
  /// way `NSTextView.linkTextAttributes` colors them. Core Text reads `CGColor`s only.
  @MainActor
  static func drawable(
    _ text: NSAttributedString,
    linkColor: NSColor?,
    appearance: NSAppearance
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    let fullRange = NSRange(location: 0, length: result.length)
    guard fullRange.length > 0 else { return result }
    appearance.performAsCurrentDrawingAppearance {
      if let linkColor {
        result.enumerateAttribute(.link, in: fullRange) { value, range, _ in
          guard value != nil else { return }
          result.addAttribute(.foregroundColor, value: linkColor, range: range)
        }
      }
      let foreground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
      result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
        let color = (value as? NSColor) ?? .labelColor
        result.addAttribute(foreground, value: color.cgColor, range: range)
      }
      // Underlines and strikethroughs are drawn by `CoreTextGlyphView` where TextKit draws them;
      // Core Text's own land elsewhere. Keep styles and colors under keys Core Text doesn't read.
      result.enumerateAttribute(.underlineStyle, in: fullRange) { value, range, _ in
        guard let style = value as? Int, style != 0 else { return }
        result.removeAttribute(.underlineStyle, range: range)
        result.addAttribute(underlineStyleKey, value: style, range: range)
      }
      result.enumerateAttribute(.underlineColor, in: fullRange) { value, range, _ in
        guard let color = value as? NSColor else { return }
        result.addAttribute(underlineColorKey, value: color.cgColor, range: range)
      }
      // Core Text paints NSBackgroundColor on its own glyph boxes; `CoreTextGlyphView` fills the
      // line boxes TextKit fills instead.
      result.enumerateAttribute(.backgroundColor, in: fullRange) { value, range, _ in
        guard let color = value as? NSColor else { return }
        result.removeAttribute(.backgroundColor, range: range)
        result.addAttribute(backgroundColorKey, value: color.cgColor, range: range)
      }
      result.enumerateAttribute(.strikethroughStyle, in: fullRange) { value, range, _ in
        guard let style = value as? Int, style != 0 else { return }
        result.removeAttribute(.strikethroughStyle, range: range)
        result.addAttribute(strikethroughStyleKey, value: style, range: range)
      }
      result.enumerateAttribute(.strikethroughColor, in: fullRange) { value, range, _ in
        guard let color = value as? NSColor else { return }
        result.addAttribute(strikethroughColorKey, value: color.cgColor, range: range)
      }
    }
    return result
  }

  static let underlineStyleKey = NSAttributedString.Key("inline.coreText.underlineStyle")
  static let underlineColorKey = NSAttributedString.Key("inline.coreText.underlineColor")
  static let strikethroughStyleKey = NSAttributedString.Key("inline.coreText.strikethroughStyle")
  static let strikethroughColorKey = NSAttributedString.Key("inline.coreText.strikethroughColor")
  static let backgroundColorKey = NSAttributedString.Key("inline.coreText.backgroundColor")

  /// The text box `MessageSizeCalculator` sizes the text view to: the laid-out text plus the
  /// same point of height `TextMeasurer` adds. Nil when the experiment is off or the text
  /// stays on `MessageTextView`. Colors don't affect it, so the calculator's own string works.
  static func measuredSize(_ text: NSAttributedString, width: CGFloat, extraWidth: CGFloat) -> CGSize? {
    guard isEnabled, text.length > 0, supports(text) else { return nil }
    installAppKitLineMetrics()
    let layout = TextLayouter.layout(
      MessageText(text),
      style: style(for: text, isRtl: false, forcesDirection: false),
      maximumWidth: max(1, ceil(width)),
      grid: PixelGrid(scale: 2)
    )
    return CGSize(width: ceil(layout.size.width) + extraWidth, height: ceil(layout.size.height) + 1)
  }

  /// Typeset message text, shared by every Core Text message view.
  static let layoutCache = TextLayoutCache(characterBudget: 600_000)

  static func layout(
    _ drawable: NSAttributedString,
    style: TextLayoutStyle,
    width: CGFloat,
    scale: CGFloat
  ) -> TextLayout {
    installAppKitLineMetrics()
    return layoutCache.layout(
      MessageText(drawable),
      style: style,
      maximumWidth: width,
      grid: PixelGrid(scale: scale)
    )
    .aligned(toWidth: width)
  }

  /// Line boxes from AppKit itself, so legacy fonts (Helvetica, Courier, Palatino) get the
  /// same extra height `NSTextView` gives them.
  static func installAppKitLineMetrics() {
    _ = appKitLineMetricsInstalled
  }

  private static let appKitLineMetricsInstalled: Bool = {
    FontLineMetricsProvider.install { font in AppKitLineMetrics.metrics(for: font) }
    return true
  }()
}

/// `NSLayoutManager.defaultLineHeight(for:)` per font, with the baseline where TextKit puts it:
/// one rounded descent above the bottom. Measured against TextKit 2 on macOS 27, glyphs and
/// color emoji drawn there match its pixels at 1x and 2x.
enum AppKitLineMetrics {
  private static let cache = Mutex<[String: FontLineMetrics]>([:])

  static func metrics(for font: CTFont) -> FontLineMetrics {
    let key = "\(CTFontCopyPostScriptName(font))|\(CTFontGetSize(font))"
    if let cached = cache.withLock({ $0[key] }) { return cached }
    let height = NSLayoutManager().defaultLineHeight(for: font as NSFont)
    let descent = CTFontGetDescent(font).rounded()
    let metrics = FontLineMetrics(height: height, baseline: height - descent)
    cache.withLock { $0[key] = metrics }
    return metrics
  }
}
