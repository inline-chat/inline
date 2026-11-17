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

  /// Whether a message with these entities can be drawn here, decided before its text is built.
  /// Plain text marks math as source (formulas become attachments only in rich blocks, which
  /// draw themselves), so every entity is supported; `supports(_:)` still guards attachments.
  static func supports(entities _: MessageEntities?) -> Bool {
    true
  }

  /// Whether this renderer draws `text`: everything but attachments (inline math).
  static func supports(_ text: NSAttributedString) -> Bool {
    guard text.length > 0 else { return true }
    var supported = true
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
      if value != nil {
        supported = false
        stop.pointee = true
      }
    }
    return supported
  }

  /// Text-to-layout style matching how `MessageTextView` sets text: one base direction for the
  /// whole message and TextKit's line boxes. Spacing and indents come from each paragraph's
  /// style (see `layoutText`).
  static func style(for _: NSAttributedString, isRtl: Bool) -> TextLayoutStyle {
    TextLayoutStyle(lineHeight: .fontDefault, baseDirection: isRtl ? .rightToLeft : .leftToRight)
  }

  static func paragraphMetrics(_ style: NSParagraphStyle) -> TextParagraphMetrics {
    TextParagraphMetrics(
      firstLineHeadIndent: style.firstLineHeadIndent,
      headIndent: style.headIndent,
      tailIndent: style.tailIndent,
      lineSpacing: style.lineSpacing,
      spacingBefore: style.paragraphSpacingBefore,
      spacingAfter: style.paragraphSpacing
    )
  }

  /// What the glyph view paints with: `text` with its colors resolved for `appearance` as
  /// `CGColor`s, links colored the way `NSTextView.linkTextAttributes` colors them, and
  /// decorations under private keys. The layout never sees these, so measuring and drawing share
  /// one layout and an appearance change only repaints.
  @MainActor
  static func paint(
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
      result.enumerateAttribute(.codeBlockBackground, in: fullRange) { value, range, _ in
        guard let color = value as? NSColor else { return }
        result.addAttribute(codeBlockColorKey, value: color.cgColor, range: range)
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
  static let codeBlockColorKey = NSAttributedString.Key("inline.coreText.codeBlockColor")

  /// The text box `MessageSizeCalculator` sizes the text view to: the laid-out text plus the
  /// same point of height `TextMeasurer` adds. Nil when the experiment is off or the text
  /// stays on `MessageTextView`. The layout it makes is the one the view then draws.
  static func measuredSize(_ text: NSAttributedString, isRtl: Bool, width: CGFloat, extraWidth: CGFloat) -> CGSize? {
    guard isEnabled, text.length > 0, supports(text) else { return nil }
    let layout = layout(text, isRtl: isRtl, width: width)
    return CGSize(width: ceil(layout.size.width) + extraWidth, height: ceil(layout.size.height) + 1)
  }

  /// Attributes that move glyphs. Everything else (colors, links, decorations) is painted.
  private static let layoutKeys: [NSAttributedString.Key] = [
    .font, .paragraphStyle, .kern, .tracking, .ligature, .baselineOffset, .superscript, .expansion,
    .verticalGlyphForm, NSAttributedString.Key(kCTRunDelegateAttributeName as String),
  ]

  /// `text` reduced to what decides where glyphs go, drawn in the context's fill color. The
  /// size calculator's string and the view's (which adds link styling) reduce to the same text.
  static func layoutText(_ text: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text.string)
    let fullRange = NSRange(location: 0, length: text.length)
    guard fullRange.length > 0 else { return result }
    text.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
      var kept: [NSAttributedString.Key: Any] = [:]
      for key in layoutKeys {
        if let value = attributes[key] { kept[key] = value }
      }
      if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
        kept[TextParagraphMetrics.attributeKey] = paragraphMetrics(paragraph)
      }
      if !kept.isEmpty { result.setAttributes(kept, range: range) }
    }
    result.addAttribute(
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String),
      value: true,
      range: fullRange
    )
    return result
  }

  /// The layout of `text` (display or measuring string) for a text box `width` wide.
  ///
  /// A layout made for one width is reused for any width it still fits, down to its widest
  /// line: the size calculator lays text out at the space available, and the view then asks at
  /// the width that came out, so each message is typeset once.
  static func layout(_ text: NSAttributedString, isRtl: Bool, width: CGFloat) -> TextLayout {
    installAppKitLineMetrics()
    let width = max(1, ceil(width))
    let key = LayoutKey(text: MessageText(layoutText(text)), style: style(for: text, isRtl: isRtl))
    if let entry = layouts.object(forKey: key),
       entry.layout.size.width <= width + 0.01, width <= entry.width + 0.01
    {
      return entry.layout
    }
    let layout = TextLayouter.layout(key.text, style: key.style, maximumWidth: width, grid: PixelGrid(scale: 2))
    layouts.setObject(LayoutEntry(layout: layout, width: width), forKey: key, cost: max(1, text.length))
    return layout
  }

  private static let layouts: NSCache<LayoutKey, LayoutEntry> = {
    let cache = NSCache<LayoutKey, LayoutEntry>()
    cache.totalCostLimit = 600_000
    return cache
  }()

  private final class LayoutKey: NSObject, @unchecked Sendable {
    let text: MessageText
    let style: TextLayoutStyle
    init(text: MessageText, style: TextLayoutStyle) {
      self.text = text
      self.style = style
    }

    override var hash: Int { text.hashValue ^ style.hashValue }
    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? LayoutKey else { return false }
      return other.style == style && other.text == text
    }
  }

  private final class LayoutEntry: NSObject, @unchecked Sendable {
    let layout: TextLayout
    let width: CGFloat
    init(layout: TextLayout, width: CGFloat) {
      self.layout = layout
      self.width = width
    }
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
