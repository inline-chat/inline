import InlineIOSUI
import InlineKit
import InlineProtocol
import InlineUI
import UIKit

private func richTextCharacterIndex(
  at point: CGPoint,
  in textView: UITextView,
  hitSlop: CGFloat = 2
) -> Int? {
  guard textView.bounds.contains(point),
        let attributedText = textView.attributedText,
        attributedText.length > 0
  else { return nil }

  let textContainer = textView.textContainer
  let layoutManager = textView.layoutManager
  let containerPoint = CGPoint(
    x: point.x - textView.textContainerInset.left + textView.contentOffset.x,
    y: point.y - textView.textContainerInset.top + textView.contentOffset.y
  )
  layoutManager.ensureLayout(for: textContainer)
  guard layoutManager.usedRect(for: textContainer)
    .insetBy(dx: -hitSlop, dy: -hitSlop)
    .contains(containerPoint)
  else { return nil }

  var fraction: CGFloat = 0
  let glyph = layoutManager.glyphIndex(
    for: containerPoint,
    in: textContainer,
    fractionOfDistanceThroughGlyph: &fraction
  )
  guard glyph < layoutManager.numberOfGlyphs else { return nil }
  let glyphRect = layoutManager.boundingRect(
    forGlyphRange: NSRange(location: glyph, length: 1),
    in: textContainer
  )
  guard glyphRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(containerPoint) else {
    return nil
  }
  let character = layoutManager.characterIndexForGlyph(at: glyph)
  return character < attributedText.length ? character : nil
}

struct RichBlockPaletteV2 {
  let primary: UIColor
  let secondary: UIColor
  let accent: UIColor
  let subtleFill: UIColor
  let codeFill: UIColor
  let separator: UIColor
  let placeholder: UIColor
}

struct RichBlockImageGallerySelectionV2 {
  let photos: [PhotoInfo]
  let initialIndex: Int
  let sourceView: UIView
  let sourceImage: UIImage?
}

private struct RichBlockRenderContextV2 {
  let attributedText: NSAttributedString
  let baseFontSize: CGFloat
  let palette: RichBlockPaletteV2
  let message: InlineKit.Message
  let onDisclosureToggle: (BlockContentPath, Bool) -> Void
  let onEntityTap: (NSAttributedString, Int) -> Void
  let onImageTap: (RichBlockImageGallerySelectionV2) -> Void

  func text(for node: RichBlockLayoutPlanV2.TextNode) -> NSAttributedString {
    if let literal = node.literal {
      return NSAttributedString(
        string: literal,
        attributes: [
          .font: UIFont.systemFont(ofSize: baseFontSize),
          .foregroundColor: palette.primary,
        ]
      )
    }
    return RichBlockLayoutPlannerV2.styledText(
      from: attributedText,
      range: node.range,
      role: node.role,
      baseFontSize: baseFontSize,
      isRTL: node.isRTL
    ) ?? NSAttributedString(string: "")
  }
}

private class RichBlockRenderableViewV2: UIView {
  let reuseKind: RichBlockRenderKindV2

  init(_ reuseKind: RichBlockRenderKindV2) {
    self.reuseKind = reuseKind
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {}
  func updateLayout(node: RichBlockLayoutPlanV2.Node) {}
  func prepareForReuse() {
    alpha = 1
    transform = .identity
  }
}

private protocol RichBlockEntityHittableV2: AnyObject {
  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)?
}

private protocol RichBlockTextSurfaceProvidingV2: AnyObject {
  var textSurface: UITextView { get }
}

private final class RichBlockTextNodeViewV2: RichBlockRenderableViewV2,
  RichBlockEntityHittableV2,
  RichBlockTextSurfaceProvidingV2
{
  private let textView = CodeBlockTextView()
  var textSurface: UITextView {
    textView
  }

  private var onEntityTap: ((NSAttributedString, Int) -> Void)?

  init(kind: RichBlockRenderKindV2 = .text) {
    super.init(kind)
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = false
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.dataDetectorTypes = []
    textView.isUserInteractionEnabled = true
    addSubview(textView)
    textView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    textView.frame = bounds
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .text(text) = node.kind else { return }
    textView.attributedText = context.text(for: text)
    onEntityTap = context.onEntityTap
    isAccessibilityElement = true
    accessibilityLabel = textView.attributedText.string
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let hit = entityHit(at: gesture.location(in: self)) else { return }
    onEntityTap?(hit.text, hit.characterIndex)
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard let attributedText = textView.attributedText, attributedText.length > 0 else { return nil }
    let point = convert(point, to: textView)
    guard let character = richTextCharacterIndex(at: point, in: textView) else { return nil }
    return (attributedText, character)
  }
}

private final class RichBlockListMarkerNodeViewV2: RichBlockRenderableViewV2 {
  private var marker = ""
  private var isRTL = false
  private var color = UIColor.label
  private var font = UIFont.systemFont(ofSize: 17)

  init() {
    super.init(.listMarker)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    isOpaque = false
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .text(text) = node.kind,
          case .listMarker = text.role,
          let marker = text.literal
    else { return }
    self.marker = marker
    isRTL = text.isRTL
    color = context.palette.primary
    font = .systemFont(ofSize: context.baseFontSize)
    setNeedsDisplay()
    isAccessibilityElement = false
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard !marker.isEmpty else { return }
    if marker == "•" {
      let diameter = max(4.25, font.pointSize * 0.27)
      let x = isRTL ? bounds.width - diameter : 0
      let lineHeight = ceil(font.lineHeight)
      let markerRect = CGRect(
        x: floor(x),
        y: floor((min(bounds.height, lineHeight) - diameter) / 2) + 1,
        width: diameter,
        height: diameter
      )
      color.setFill()
      UIBezierPath(ovalIn: markerRect).fill()
      return
    }

    if marker == "☐" || marker == "☑" {
      let side = min(12, max(9, font.pointSize * 0.72))
      let x = isRTL ? bounds.width - side : 0
      let markerRect = CGRect(
        x: floor(x) + 0.5,
        y: floor((min(bounds.height, font.lineHeight) - side) / 2) + 1.5,
        width: side,
        height: side
      )
      let box = UIBezierPath(roundedRect: markerRect, cornerRadius: 2)
      box.lineWidth = 1.25
      color.withAlphaComponent(0.72).setStroke()
      box.stroke()
      if marker == "☑" {
        let check = UIBezierPath()
        check.lineWidth = 1.55
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: CGPoint(x: markerRect.minX + side * 0.22, y: markerRect.midY))
        check.addLine(to: CGPoint(x: markerRect.minX + side * 0.43, y: markerRect.maxY - side * 0.25))
        check.addLine(to: CGPoint(x: markerRect.maxX - side * 0.18, y: markerRect.minY + side * 0.24))
        color.setStroke()
        check.stroke()
      }
      return
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = isRTL ? .right : .left
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    (marker as NSString).draw(
      in: bounds,
      withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    marker = ""
  }
}

private final class RichBlockTextShimmerViewV2: UIView {
  private let gradient = CAGradientLayer()
  private let glyphMask = CALayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    gradient.colors = [
      UIColor.clear.cgColor,
      UIColor.white.withAlphaComponent(0.92).cgColor,
      UIColor.clear.cgColor,
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    gradient.locations = [0, 0.12, 0.24]
    layer.addSublayer(gradient)
    layer.mask = glyphMask
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
    glyphMask.frame = bounds
  }

  func updateMask(from textView: UITextView) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    textView.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = max(window?.screen.scale ?? UIScreen.main.scale, 1)
    let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
    let image = renderer.image { context in
      textView.layer.render(in: context.cgContext)
    }
    glyphMask.contents = image.cgImage
    glyphMask.contentsScale = format.scale
  }

  func setAnimating(_ animating: Bool) {
    if animating {
      guard gradient.animation(forKey: "rich-disclosure-shimmer") == nil else { return }
      let animation = CABasicAnimation(keyPath: "locations")
      animation.fromValue = [-0.2, -0.1, 0]
      animation.toValue = [1, 1.1, 1.2]
      animation.duration = 1.55
      animation.repeatCount = .infinity
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      gradient.add(animation, forKey: "rich-disclosure-shimmer")
    } else {
      gradient.removeAnimation(forKey: "rich-disclosure-shimmer")
    }
  }
}

private final class RichBlockDisclosureNodeViewV2: RichBlockRenderableViewV2,
  RichBlockEntityHittableV2
{
  private let title = CodeBlockTextView()
  private let chevron = UIImageView()
  private let shimmer = RichBlockTextShimmerViewV2()
  private var path = BlockContentPath()
  private var expanded = false
  private var progress = false
  private var isRTL = false
  private var onToggle: ((BlockContentPath, Bool) -> Void)?
  private var onEntityTap: ((NSAttributedString, Int) -> Void)?

  init() {
    super.init(.disclosure)
    title.backgroundColor = .clear
    title.isEditable = false
    title.isSelectable = false
    title.isScrollEnabled = false
    title.textContainerInset = .zero
    title.textContainer.lineFragmentPadding = 0
    title.isUserInteractionEnabled = false
    chevron.contentMode = .scaleAspectFit
    addSubview(title)
    addSubview(chevron)
    addSubview(shimmer)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    isAccessibilityElement = true
    accessibilityTraits = [.button]
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reduceMotionStatusDidChange),
      name: UIAccessibility.reduceMotionStatusDidChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .text(text) = node.kind,
          case let .disclosure(progress, isExpanded) = text.role
    else { return }
    path = node.path
    expanded = isExpanded
    self.progress = progress
    isRTL = text.isRTL
    onToggle = context.onDisclosureToggle
    onEntityTap = context.onEntityTap
    let attributed = NSMutableAttributedString(attributedString: context.text(for: text))
    if progress {
      attributed.addAttribute(
        .foregroundColor,
        value: context.palette.primary.withAlphaComponent(0.78),
        range: NSRange(location: 0, length: attributed.length)
      )
    }
    title.attributedText = attributed
    updateChevron()
    chevron.tintColor = context.palette.secondary
    backgroundColor = .clear
    shimmer.isHidden = !progress
    accessibilityLabel = attributed.string
    accessibilityValue = isExpanded ? "Expanded" : "Collapsed"
    updateShimmerAnimation()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let chevronSide = min(CGFloat(14), bounds.height)
    let gap: CGFloat = 4
    let titleViewport = max(1, bounds.width - chevronSide - gap)
    title.frame = CGRect(x: 0, y: 0, width: titleViewport, height: bounds.height)
    title.layoutIfNeeded()
    let usedWidth = min(
      titleViewport,
      max(1, ceil(title.layoutManager.usedRect(for: title.textContainer).width))
    )
    if isRTL {
      title.frame = CGRect(x: bounds.width - usedWidth, y: 0, width: usedWidth, height: bounds.height)
      chevron.frame = CGRect(
        x: max(0, title.frame.minX - gap - chevronSide),
        y: floor((bounds.height - chevronSide) / 2),
        width: chevronSide,
        height: chevronSide
      )
    } else {
      title.frame = CGRect(x: 0, y: 0, width: usedWidth, height: bounds.height)
      chevron.frame = CGRect(
        x: min(bounds.width - chevronSide, title.frame.maxX + gap),
        y: floor((bounds.height - chevronSide) / 2),
        width: chevronSide,
        height: chevronSide
      )
    }
    shimmer.frame = title.frame
    shimmer.updateMask(from: title)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateShimmerAnimation()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onToggle = nil
    onEntityTap = nil
    shimmer.setAnimating(false)
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    let point = gesture.location(in: self)
    if let hit = entityHit(at: point),
       isInteractiveEntity(in: hit.text, at: hit.characterIndex)
    {
      onEntityTap?(hit.text, hit.characterIndex)
      return
    }
    expanded.toggle()
    updateChevron()
    accessibilityValue = expanded ? "Expanded" : "Collapsed"
    onToggle?(path, expanded)
  }

  override func accessibilityActivate() -> Bool {
    expanded.toggle()
    updateChevron()
    accessibilityValue = expanded ? "Expanded" : "Collapsed"
    onToggle?(path, expanded)
    return true
  }

  @objc private func reduceMotionStatusDidChange() {
    updateShimmerAnimation()
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard let text = title.attributedText, text.length > 0 else { return nil }
    let titlePoint = convert(point, to: title)
    guard title.bounds.contains(titlePoint) else { return nil }
    guard let character = richTextCharacterIndex(at: titlePoint, in: title) else { return nil }
    return (text, character)
  }

  private func isInteractiveEntity(in text: NSAttributedString, at index: Int) -> Bool {
    let attributes = text.attributes(at: index, effectiveRange: nil)
    return attributes[.link] != nil
      || attributes[.mentionUserId] != nil
      || attributes[.mentionGroupId] != nil
      || attributes[.threadLink] != nil
      || attributes[.inlineCode] != nil
      || attributes[.botCommand] != nil
      || attributes[.emailAddress] != nil
      || attributes[.phoneNumber] != nil
  }

  private func updateChevron() {
    let symbol = expanded ? "chevron.down" : (isRTL ? "chevron.left" : "chevron.right")
    chevron.image = UIImage(systemName: symbol)
  }

  private func updateShimmerAnimation() {
    let shouldAnimate = progress
      && window != nil
      && !UIAccessibility.isReduceMotionEnabled
    shimmer.setAnimating(shouldAnimate)
  }
}

private enum RichCodeTokenKindV2 {
  case keyword
  case type
  case function
  case string
  case number
  case comment
  case punctuation
}

private struct RichCodeTokenV2 {
  let range: NSRange
  let kind: RichCodeTokenKindV2
}

/// Bounded lexical coloring keeps code readable without pulling every Tree-sitter grammar into
/// the default-off iOS binary. The macOS semantic highlighter remains the richer reference.
private enum RichCodeSyntaxHighlighterV2 {
  private static let maximumUTF16Length = 100_000
  private static let maximumLines = 5_000

  static func supports(language: String?) -> Bool {
    normalized(language) != nil
  }

  static func tokens(for text: String, language: String?) -> [RichCodeTokenV2] {
    guard let language = normalized(language),
          text.utf16.count <= maximumUTF16Length,
          text.lazy.filter({ $0 == "\n" }).prefix(maximumLines).count < maximumLines
    else { return [] }

    let fullRange = NSRange(location: 0, length: (text as NSString).length)
    var candidates: [(priority: Int, token: RichCodeTokenV2)] = []
    func append(pattern: String, kind: RichCodeTokenKindV2, priority: Int, options: NSRegularExpression.Options = []) {
      guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
      for match in expression.matches(in: text, range: fullRange) where match.range.length > 0 {
        candidates.append((priority, .init(range: match.range, kind: kind)))
      }
    }

    if ["python", "bash", "yaml"].contains(language) {
      append(pattern: "#[^\\n]*", kind: .comment, priority: 0)
    } else if language == "html" {
      append(pattern: "<!--[\\s\\S]*?-->", kind: .comment, priority: 0)
    } else {
      append(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/", kind: .comment, priority: 0)
    }
    append(
      pattern: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#,
      kind: .string,
      priority: 1
    )
    append(pattern: #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, kind: .number, priority: 2)

    let keywords = keywordSet(for: language)
    if !keywords.isEmpty {
      let body = keywords.map(NSRegularExpression.escapedPattern).joined(separator: "|")
      append(pattern: "\\b(?:\(body))\\b", kind: .keyword, priority: 3)
    }
    append(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, kind: .function, priority: 4)
    if ["swift", "typescript", "tsx", "go", "rust"].contains(language) {
      append(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .type, priority: 5)
    }
    append(pattern: #"[{}\[\](),.;:]"#, kind: .punctuation, priority: 6)

    var occupied = IndexSet()
    var accepted: [RichCodeTokenV2] = []
    for candidate in candidates.sorted(by: {
      $0.priority == $1.priority ? $0.token.range.location < $1.token.range.location : $0.priority < $1.priority
    }) {
      let range = candidate.token.range.location ..< NSMaxRange(candidate.token.range)
      guard !occupied.intersects(integersIn: range) else { continue }
      occupied.insert(integersIn: range)
      accepted.append(candidate.token)
    }
    return accepted.sorted { $0.range.location < $1.range.location }
  }

  private static func normalized(_ language: String?) -> String? {
    guard let value = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return nil
    }
    return switch value {
      case "swift", "swift5", "swift6": "swift"
      case "typescript", "ts", "javascript", "js": "typescript"
      case "tsx", "jsx": "tsx"
      case "python", "py", "python3": "python"
      case "bash", "sh", "shell", "zsh": "bash"
      case "html", "htm": "html"
      case "css", "scss": "css"
      case "json", "jsonc": "json"
      case "yaml", "yml": "yaml"
      case "go", "golang": "go"
      case "rust", "rs": "rust"
      default: nil
    }
  }

  private static func keywordSet(for language: String) -> [String] {
    switch language {
      case "swift": [
          "actor",
          "as",
          "async",
          "await",
          "break",
          "case",
          "catch",
          "class",
          "continue",
          "default",
          "defer",
          "do",
          "else",
          "enum",
          "extension",
          "false",
          "for",
          "func",
          "guard",
          "if",
          "import",
          "in",
          "init",
          "let",
          "nil",
          "protocol",
          "return",
          "self",
          "some",
          "struct",
          "switch",
          "throw",
          "throws",
          "true",
          "try",
          "var",
          "where",
          "while",
        ]
      case "typescript", "tsx": [
          "async",
          "await",
          "break",
          "case",
          "catch",
          "class",
          "const",
          "continue",
          "default",
          "delete",
          "do",
          "else",
          "export",
          "extends",
          "false",
          "finally",
          "for",
          "from",
          "function",
          "if",
          "import",
          "in",
          "instanceof",
          "interface",
          "let",
          "new",
          "null",
          "of",
          "return",
          "static",
          "switch",
          "throw",
          "true",
          "try",
          "type",
          "typeof",
          "undefined",
          "var",
          "while",
        ]
      case "python": [
          "and",
          "as",
          "assert",
          "async",
          "await",
          "break",
          "class",
          "continue",
          "def",
          "del",
          "elif",
          "else",
          "except",
          "False",
          "finally",
          "for",
          "from",
          "global",
          "if",
          "import",
          "in",
          "is",
          "lambda",
          "None",
          "not",
          "or",
          "pass",
          "raise",
          "return",
          "True",
          "try",
          "while",
          "with",
          "yield",
        ]
      case "bash": [
          "case",
          "do",
          "done",
          "elif",
          "else",
          "esac",
          "fi",
          "for",
          "function",
          "if",
          "in",
          "select",
          "then",
          "time",
          "until",
          "while",
        ]
      case "go": [
          "break",
          "case",
          "chan",
          "const",
          "continue",
          "default",
          "defer",
          "else",
          "fallthrough",
          "for",
          "func",
          "go",
          "goto",
          "if",
          "import",
          "interface",
          "map",
          "package",
          "range",
          "return",
          "select",
          "struct",
          "switch",
          "type",
          "var",
        ]
      case "rust": [
          "as",
          "async",
          "await",
          "break",
          "const",
          "continue",
          "crate",
          "dyn",
          "else",
          "enum",
          "extern",
          "false",
          "fn",
          "for",
          "if",
          "impl",
          "in",
          "let",
          "loop",
          "match",
          "mod",
          "move",
          "mut",
          "pub",
          "ref",
          "return",
          "self",
          "static",
          "struct",
          "super",
          "trait",
          "true",
          "type",
          "unsafe",
          "use",
          "where",
          "while",
        ]
      case "json": ["false", "null", "true"]
      default: []
    }
  }
}

private final class RichBlockCodeNodeViewV2: RichBlockRenderableViewV2, RichBlockTextSurfaceProvidingV2 {
  private let languageLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let gutterLabel = UILabel()
  private let scrollView = UIScrollView()
  private let textView = UITextView()
  var textSurface: UITextView {
    textView
  }

  private var code = ""
  private var language: String?
  private var gutterWidth: CGFloat = 0
  private var codeContentWidth: CGFloat = 0
  private var highlightGeneration: UInt64 = 0
  private var highlightTask: Task<Void, Never>?
  private var copyFeedbackTask: Task<Void, Never>?

  init() {
    super.init(.code)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    layer.borderWidth = 0
    clipsToBounds = true
    languageLabel.font = .systemFont(ofSize: 10, weight: .medium)
    gutterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    gutterLabel.numberOfLines = 0
    gutterLabel.textAlignment = .right
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byClipping
    scrollView.alwaysBounceVertical = false
    scrollView.isDirectionalLockEnabled = true
    scrollView.showsHorizontalScrollIndicator = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.addSubview(textView)
    copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
    copyButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 13, weight: .medium),
      forImageIn: .normal
    )
    copyButton.imageView?.contentMode = .scaleAspectFit
    copyButton.accessibilityLabel = "Copy code"
    copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
    addSubview(gutterLabel)
    addSubview(scrollView)
    addSubview(languageLabel)
    addSubview(copyButton)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .code(codeNode) = node.kind,
          codeNode.range.location >= 0,
          NSMaxRange(codeNode.range) <= context.attributedText.length
    else { return }
    code = context.attributedText.attributedSubstring(from: codeNode.range).string
    language = codeNode.language
    gutterWidth = codeNode.gutterWidth
    codeContentWidth = codeNode.contentWidth
    languageLabel.text = codeNode.language.map(Self.displayLanguage)
    languageLabel.textColor = context.palette.secondary
    copyButton.tintColor = context.palette.secondary
    backgroundColor = context.palette.codeFill
    gutterLabel.font = .monospacedDigitSystemFont(
      ofSize: context.baseFontSize * 0.9,
      weight: .regular
    )
    textView.attributedText = NSAttributedString(
      string: code,
      attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: context.baseFontSize * 0.9, weight: .regular),
        .foregroundColor: context.palette.primary,
      ]
    )
    gutterLabel.text = codeNode.gutterWidth > 0
      ? (1 ... codeNode.lineCount).map(String.init).joined(separator: "\n")
      : nil
    gutterLabel.textColor = context.palette.secondary.withAlphaComponent(0.7)
    gutterLabel.isHidden = codeNode.gutterWidth == 0
    requestHighlight(
      primary: context.palette.primary,
      secondary: context.palette.secondary,
      accent: context.palette.accent
    )
    setNeedsLayout()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      highlightGeneration &+= 1
      highlightTask?.cancel()
      highlightTask = nil
      copyFeedbackTask?.cancel()
      copyFeedbackTask = nil
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    highlightGeneration &+= 1
    highlightTask?.cancel()
    highlightTask = nil
    copyFeedbackTask?.cancel()
    copyFeedbackTask = nil
    setCopyFeedback(copied: false)
    code = ""
    language = nil
    gutterWidth = 0
    codeContentWidth = 0
    scrollView.contentOffset = .zero
  }

  override func updateLayout(node _: RichBlockLayoutPlanV2.Node) {
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let hasLanguage = languageLabel.text?.isEmpty == false
    let headerHeight: CGFloat = hasLanguage ? 21 : 0
    let bodyTopInset: CGFloat = hasLanguage ? 3 : 8
    languageLabel.frame = CGRect(x: 8, y: 5, width: max(0, bounds.width - 44), height: 14)
    copyButton.frame = CGRect(x: bounds.width - 26, y: hasLanguage ? 3 : 4, width: 18, height: 18)
    let gutterWidth = gutterLabel.isHidden ? CGFloat.zero : gutterWidth
    gutterLabel.frame = CGRect(
      x: 8,
      y: headerHeight + bodyTopInset,
      width: gutterWidth,
      height: bounds.height - headerHeight - bodyTopInset - 9
    )
    let gutterGap: CGFloat = gutterWidth > 0 ? 15 : 0
    let viewportFrame = CGRect(
      x: 8 + gutterWidth + gutterGap,
      y: headerHeight + bodyTopInset,
      width: max(0, bounds.width - 16 - gutterWidth - gutterGap),
      height: max(0, bounds.height - headerHeight - bodyTopInset - 9)
    )
    scrollView.frame = viewportFrame
    let textWidth = max(viewportFrame.width, codeContentWidth)
    textView.frame = CGRect(origin: .zero, size: CGSize(width: textWidth, height: viewportFrame.height))
    scrollView.contentSize = textView.bounds.size
    scrollView.alwaysBounceHorizontal = textWidth > viewportFrame.width + 1
    bringSubviewToFront(languageLabel)
    bringSubviewToFront(copyButton)
  }

  @objc private func copyCode() {
    UIPasteboard.general.string = code
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    copyFeedbackTask?.cancel()
    setCopyFeedback(copied: true)
    copyFeedbackTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      self?.setCopyFeedback(copied: false)
    }
  }

  private func setCopyFeedback(copied: Bool) {
    let symbol = copied ? "checkmark" : "doc.on.doc"
    copyButton.setImage(UIImage(systemName: symbol), for: .normal)
    copyButton.accessibilityLabel = copied ? "Copied" : "Copy code"
  }

  private static func displayLanguage(_ language: String) -> String {
    let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
    return switch trimmed.lowercased() {
      case "bash", "sh", "shell", "zsh": "Shell"
      case "c": "C"
      case "c#", "csharp", "cs": "C#"
      case "c++", "cpp": "C++"
      case "css": "CSS"
      case "go", "golang": "Go"
      case "html": "HTML"
      case "javascript", "js": "JavaScript"
      case "json", "jsonc": "JSON"
      case "jsx": "JSX"
      case "kotlin": "Kotlin"
      case "objective-c", "objc": "Objective-C"
      case "python", "py", "python3": "Python"
      case "ruby", "rb": "Ruby"
      case "rust", "rs": "Rust"
      case "sql", "postgres", "postgresql": "SQL"
      case "swift": "Swift"
      case "tsx": "TSX"
      case "typescript", "ts": "TypeScript"
      case "xml": "XML"
      case "yaml", "yml": "YAML"
      default: trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
  }

  private func requestHighlight(primary: UIColor, secondary: UIColor, accent: UIColor) {
    highlightGeneration &+= 1
    let generation = highlightGeneration
    highlightTask?.cancel()
    guard RichCodeSyntaxHighlighterV2.supports(language: language), !code.isEmpty else {
      highlightTask = nil
      return
    }

    let code = code
    let language = language
    let font = textView.font ?? UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    highlightTask = Task { @MainActor [weak self] in
      let tokens = await Task.detached(priority: .utility) {
        RichCodeSyntaxHighlighterV2.tokens(for: code, language: language)
      }.value
      guard !Task.isCancelled,
            let self,
            highlightGeneration == generation,
            self.code == code
      else { return }

      let highlighted = NSMutableAttributedString(
        string: code,
        attributes: [.font: font, .foregroundColor: primary]
      )
      for token in tokens where token.range.location >= 0
        && token.range.location <= highlighted.length
        && token.range.length <= highlighted.length - token.range.location
      {
        highlighted.addAttribute(
          .foregroundColor,
          value: Self.tokenColor(token.kind, primary: primary, secondary: secondary, accent: accent),
          range: token.range
        )
      }
      textView.attributedText = highlighted
    }
  }

  private static func tokenColor(
    _ kind: RichCodeTokenKindV2,
    primary: UIColor,
    secondary: UIColor,
    accent: UIColor
  ) -> UIColor {
    switch kind {
      case .keyword, .number:
        accent
      case .type:
        accent
      case .function:
        primary
      case .string:
        secondary
      case .comment:
        secondary.withAlphaComponent(0.72)
      case .punctuation:
        secondary
    }
  }
}

private final class RichBlockImageNodeViewV2: RichBlockRenderableViewV2 {
  private let photoView = PlatformPhotoView()
  private let unavailable = UIImageView(image: UIImage(systemName: "photo"))
  private var currentPhoto: PhotoInfo?
  private var galleryPhotos: [PhotoInfo] = []
  private var galleryIndex = 0
  private var onImageTap: ((RichBlockImageGallerySelectionV2) -> Void)?

  init() {
    super.init(.image)
    layer.cornerRadius = 7
    clipsToBounds = true
    photoView.translatesAutoresizingMaskIntoConstraints = true
    photoView.photoContentMode = .aspectFill
    photoView.showsTinyThumbnailBackground = true
    unavailable.contentMode = .scaleAspectFit
    addSubview(photoView)
    addSubview(unavailable)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openImage)))
    isAccessibilityElement = true
  }

  func apply(
    image: RichBlockLayoutPlanV2.ImageNode,
    palette: RichBlockPaletteV2,
    message: InlineKit.Message,
    galleryPhotos: [PhotoInfo]? = nil,
    galleryIndex: Int = 0,
    onImageTap: @escaping (RichBlockImageGallerySelectionV2) -> Void
  ) {
    backgroundColor = palette.placeholder
    unavailable.tintColor = palette.secondary
    switch image.state {
      case .pending:
        currentPhoto = nil
        self.galleryPhotos = []
        self.galleryIndex = 0
        self.onImageTap = nil
        photoView.setPhoto(nil)
        unavailable.isHidden = true
        accessibilityLabel = "Image loading"
        accessibilityTraits = [.image]
      case let .ready(photo):
        currentPhoto = photo
        self.galleryPhotos = galleryPhotos ?? [photo]
        self.galleryIndex = min(max(0, galleryIndex), max(0, self.galleryPhotos.count - 1))
        self.onImageTap = onImageTap
        photoView.setPhoto(photo, reloadMessageOnFinish: message)
        unavailable.isHidden = true
        accessibilityLabel = "Image"
        accessibilityTraits = [.image, .button]
      case .unavailable:
        currentPhoto = nil
        self.galleryPhotos = []
        self.galleryIndex = 0
        self.onImageTap = nil
        photoView.setPhoto(nil)
        unavailable.isHidden = false
        accessibilityLabel = "Image unavailable"
        accessibilityTraits = [.image]
    }
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .image(image) = node.kind else { return }
    apply(
      image: image,
      palette: context.palette,
      message: context.message,
      onImageTap: context.onImageTap
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    currentPhoto = nil
    galleryPhotos = []
    galleryIndex = 0
    onImageTap = nil
    photoView.setPhoto(nil)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    photoView.frame = bounds
    unavailable.frame = CGRect(x: (bounds.width - 24) / 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
  }

  @objc private func openImage() {
    guard currentPhoto != nil, !galleryPhotos.isEmpty else { return }
    onImageTap?(.init(
      photos: galleryPhotos,
      initialIndex: galleryIndex,
      sourceView: photoView,
      sourceImage: photoView.displayedImage
    ))
  }

  override func accessibilityActivate() -> Bool {
    guard currentPhoto != nil, !galleryPhotos.isEmpty else { return false }
    openImage()
    return true
  }

  func sourceView(forPhotoID photoID: Int64) -> UIView? {
    currentPhoto?.id == photoID ? photoView : nil
  }
}

private final class RichBlockAlbumNodeViewV2: RichBlockRenderableViewV2 {
  private let scrollView = UIScrollView()
  private var itemViews: [BlockContentPath: RichBlockImageNodeViewV2] = [:]
  private var items: [RichBlockLayoutPlanV2.ImageNode] = []

  init() {
    super.init(.album)
    scrollView.alwaysBounceHorizontal = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.isDirectionalLockEnabled = true
    addSubview(scrollView)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .album(album) = node.kind else { return }
    items = album.items
    let readyPhotos = items.compactMap { item -> PhotoInfo? in
      guard case let .ready(photo) = item.state else { return nil }
      return photo
    }
    let paths = Set(items.map(\.path))
    for path in Array(itemViews.keys) where !paths.contains(path) {
      itemViews.removeValue(forKey: path)?.removeFromSuperview()
    }
    for item in items {
      let view = itemViews[item.path] ?? {
        let view = RichBlockImageNodeViewV2()
        itemViews[item.path] = view
        scrollView.addSubview(view)
        return view
      }()
      view.apply(
        image: item,
        palette: context.palette,
        message: context.message,
        galleryPhotos: readyPhotos,
        galleryIndex: {
          guard case let .ready(photo) = item.state else { return 0 }
          return readyPhotos.firstIndex(where: { $0.id == photo.id }) ?? 0
        }(),
        onImageTap: context.onImageTap
      )
      view.frame = item.frame
    }
    scrollView.contentSize = CGSize(width: album.contentWidth, height: bounds.height)
    scrollView.alwaysBounceHorizontal = album.contentWidth > bounds.width + 1
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    scrollView.contentSize.height = bounds.height
    scrollView.alwaysBounceHorizontal = scrollView.contentSize.width > bounds.width + 1
    for item in items {
      itemViews[item.path]?.frame = item.frame
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    scrollView.setContentOffset(.zero, animated: false)
  }

  func sourceView(forPhotoID photoID: Int64) -> UIView? {
    itemViews.values.lazy.compactMap { $0.sourceView(forPhotoID: photoID) }.first
  }
}

private final class RichBlockQuoteNodeViewV2: RichBlockRenderableViewV2 {
  private let rail = UIView()
  private var isRTL = false

  init() {
    super.init(.quote)
    isUserInteractionEnabled = false
    addSubview(rail)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .quote(quote) = node.kind else { return }
    isRTL = quote.isRTL
    backgroundColor = context.palette.subtleFill
    rail.backgroundColor = context.palette.accent
    layer.cornerRadius = 7
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rail.frame = CGRect(x: isRTL ? bounds.width - 3 : 0, y: 0, width: 3, height: bounds.height)
    rail.layer.cornerRadius = 1.5
  }
}

private final class RichBlockSeparatorNodeViewV2: RichBlockRenderableViewV2 {
  init() {
    super.init(.separator)
    isUserInteractionEnabled = false
  }

  override func apply(node _: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    backgroundColor = context.palette.separator
  }
}

private final class RichBlockTableCellViewV2: UIView, RichBlockEntityHittableV2 {
  private let textView = CodeBlockTextView()
  private var onEntityTap: ((NSAttributedString, Int) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = false
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.isUserInteractionEnabled = true
    addSubview(textView)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(
    text: NSAttributedString?,
    alignment: NSTextAlignment,
    isHeader: Bool,
    palette: RichBlockPaletteV2,
    onEntityTap: @escaping (NSAttributedString, Int) -> Void
  ) {
    textView.attributedText = text
    textView.textAlignment = alignment
    self.onEntityTap = onEntityTap
    backgroundColor = .clear
    layer.borderWidth = 0
    isAccessibilityElement = true
    accessibilityLabel = text?.string
    accessibilityTraits = isHeader ? [.header] : [.staticText]
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    textView.frame = bounds.insetBy(dx: 10, dy: 7)
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard let attributedText = textView.attributedText, attributedText.length > 0 else { return nil }
    let location = convert(point, to: textView)
    guard let character = richTextCharacterIndex(at: location, in: textView) else { return nil }
    return (attributedText, character)
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let hit = entityHit(at: gesture.location(in: self)) else { return }
    onEntityTap?(hit.text, hit.characterIndex)
  }
}

private final class RichBlockTableCanvasViewV2: UIView {
  private var rowEdges: [CGFloat] = []
  private var separatorColor = UIColor.separator

  func apply(cells: [RichBlockLayoutPlanV2.TableNode.Cell], separatorColor: UIColor) {
    self.separatorColor = separatorColor
    rowEdges = Array(Set(cells.map(\.frame.maxY))).sorted()
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard !rowEdges.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
    context.saveGState()
    context.setStrokeColor(separatorColor.cgColor)
    context.setLineWidth(1 / max(window?.screen.scale ?? UIScreen.main.scale, 1))
    for edge in rowEdges where edge < bounds.height - 0.5 {
      let y = floor(edge) + 0.5 / max(window?.screen.scale ?? UIScreen.main.scale, 1)
      context.move(to: CGPoint(x: 0, y: y))
      context.addLine(to: CGPoint(x: bounds.width, y: y))
    }
    context.strokePath()
    context.restoreGState()
  }
}

private final class RichBlockTableNodeViewV2: RichBlockRenderableViewV2 {
  private let scrollView = UIScrollView()
  private let canvas = RichBlockTableCanvasViewV2()
  private var cellViews: [RichBlockTableCellViewV2] = []
  private var table: RichBlockLayoutPlanV2.TableNode?
  private var didSetInitialOffset = false
  private var lastIsRTL = false

  init() {
    super.init(.table)
    layer.cornerRadius = 7
    layer.cornerCurve = .continuous
    layer.borderWidth = 0
    clipsToBounds = true
    scrollView.backgroundColor = .clear
    scrollView.alwaysBounceHorizontal = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.addSubview(canvas)
    addSubview(scrollView)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .table(table) = node.kind else { return }
    if lastIsRTL != table.isRTL {
      didSetInitialOffset = false
      lastIsRTL = table.isRTL
    }
    self.table = table
    backgroundColor = .clear
    canvas.backgroundColor = .clear
    while cellViews.count < table.cells.count {
      let cellView = RichBlockTableCellViewV2()
      canvas.addSubview(cellView)
      cellViews.append(cellView)
    }
    for (index, cellView) in cellViews.enumerated() {
      guard index < table.cells.count else {
        cellView.isHidden = true
        continue
      }
      let cell = table.cells[index]
      cellView.isHidden = false
      cellView.frame = cell.frame
      let text = RichBlockLayoutPlannerV2.styledTableText(
        from: context.attributedText,
        range: cell.range,
        baseFontSize: context.baseFontSize,
        isRTL: table.isRTL,
        alignment: cell.alignment,
        isHeader: cell.isHeader
      )?.mutableCopy() as? NSMutableAttributedString
      if let text {
        text.addAttribute(
          .foregroundColor,
          value: context.palette.primary,
          range: NSRange(location: 0, length: text.length)
        )
      }
      let alignment: NSTextAlignment = switch cell.alignment {
        case .leading: table.isRTL ? .right : .left
        case .center: .center
        case .trailing: table.isRTL ? .left : .right
      }
      cellView.apply(
        text: text,
        alignment: alignment,
        isHeader: cell.isHeader,
        palette: context.palette,
        onEntityTap: context.onEntityTap
      )
    }
    canvas.apply(cells: table.cells, separatorColor: context.palette.separator)
    canvas.frame = CGRect(x: 0, y: 0, width: table.contentWidth, height: bounds.height)
    scrollView.contentSize = canvas.bounds.size
    scrollView.alwaysBounceHorizontal = table.contentWidth > bounds.width + 1
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    guard let table else { return }
    canvas.frame = CGRect(x: 0, y: 0, width: table.contentWidth, height: bounds.height)
    scrollView.contentSize = canvas.bounds.size
    scrollView.alwaysBounceHorizontal = table.contentWidth > bounds.width + 1
    if !didSetInitialOffset, bounds.width > 0 {
      scrollView.contentOffset.x = table.isRTL
        ? max(0, table.contentWidth - bounds.width)
        : 0
      didSetInitialOffset = true
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    table = nil
    didSetInitialOffset = false
    lastIsRTL = false
    scrollView.contentOffset = .zero
  }
}

final class RichBlockContentViewV2: UIView {
  private struct DisappearingSnapshot {
    let generation: UInt
    let view: UIView
  }

  var onDisclosureToggle: ((BlockContentPath, Bool) -> Void)?
  var onEntityTap: ((NSAttributedString, Int) -> Void)?
  var onImageTap: ((RichBlockImageGallerySelectionV2) -> Void)?

  private var nodeViews: [BlockContentPath: RichBlockRenderableViewV2] = [:]
  private var reusePool: [RichBlockRenderKindV2: [RichBlockRenderableViewV2]] = [:]
  private var previousContent: InlineProtocol.BlockContent?
  private var currentPlan: RichBlockLayoutPlanV2?
  private var disappearingSnapshots: [DisappearingSnapshot] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    plan: RichBlockLayoutPlanV2,
    content: InlineProtocol.BlockContent,
    attributedText: NSAttributedString,
    baseFontSize: CGFloat,
    palette: RichBlockPaletteV2,
    message: InlineKit.Message,
    deferLayout: Bool,
    transitionGeneration: UInt
  ) {
    let reconciliation = BlockContentReconciler.reconcile(previous: previousContent, current: content)
    previousContent = content

    for move in reconciliation.photoMoves {
      guard nodeViews[move.to] == nil,
            let moved = nodeViews.removeValue(forKey: move.from),
            moved.reuseKind == .image
      else { continue }
      nodeViews[move.to] = moved
    }

    let paths = Set(plan.nodes.map(\.path))
    for path in Array(nodeViews.keys) where !paths.contains(path) {
      guard let removed = nodeViews.removeValue(forKey: path) else { continue }
      if deferLayout { retainRemovalSnapshot(of: removed, generation: transitionGeneration) }
      enqueue(removed)
    }

    let context = RichBlockRenderContextV2(
      attributedText: attributedText,
      baseFontSize: baseFontSize,
      palette: palette,
      message: message,
      onDisclosureToggle: { [weak self] path, expanded in
        self?.onDisclosureToggle?(path, expanded)
      },
      onEntityTap: { [weak self] text, character in
        self?.onEntityTap?(text, character)
      },
      onImageTap: { [weak self] selection in
        self?.onImageTap?(selection)
      }
    )

    for node in plan.nodes {
      let view: RichBlockRenderableViewV2
      let animatesInsertion: Bool
      if reconciliation.reusablePaths.contains(node.path),
         let existing = nodeViews[node.path],
         existing.reuseKind == node.reuseKind
      {
        view = existing
        animatesInsertion = false
      } else if let existing = nodeViews.removeValue(forKey: node.path) {
        if deferLayout { retainRemovalSnapshot(of: existing, generation: transitionGeneration) }
        enqueue(existing)
        view = dequeue(kind: node.reuseKind)
        nodeViews[node.path] = view
        insertNodeView(view, for: node)
        animatesInsertion = true
      } else {
        view = dequeue(kind: node.reuseKind)
        nodeViews[node.path] = view
        insertNodeView(view, for: node)
        animatesInsertion = true
      }
      if animatesInsertion {
        view.frame = node.frame
        if deferLayout {
          view.alpha = 0
          view.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }
      }
      view.apply(node: node, context: context)
      if !deferLayout {
        view.frame = node.frame
        view.alpha = 1
        view.transform = .identity
      }
    }
    currentPlan = plan
  }

  func applyLayout(_ plan: RichBlockLayoutPlanV2) {
    currentPlan = plan
    for node in plan.nodes {
      guard let view = nodeViews[node.path], view.reuseKind == node.reuseKind else { continue }
      view.updateLayout(node: node)
      view.frame = node.frame
      view.alpha = 1
      view.transform = .identity
    }
    for snapshot in disappearingSnapshots {
      snapshot.view.alpha = 0
      snapshot.view.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
    }
  }

  func restorePresentationGeometry() {
    for view in nodeViews.values {
      guard let presentation = view.layer.presentation() else { continue }
      view.bounds = presentation.bounds
      view.center = presentation.position
      view.transform = CATransform3DGetAffineTransform(presentation.transform)
      view.alpha = CGFloat(presentation.opacity)
    }
    for snapshot in disappearingSnapshots {
      guard let presentation = snapshot.view.layer.presentation() else { continue }
      snapshot.view.bounds = presentation.bounds
      snapshot.view.center = presentation.position
      snapshot.view.transform = CATransform3DGetAffineTransform(presentation.transform)
      snapshot.view.alpha = CGFloat(presentation.opacity)
    }
  }

  var hasPendingTransitionSnapshots: Bool {
    !disappearingSnapshots.isEmpty
  }

  func finishTransition(generation: UInt) {
    for snapshot in disappearingSnapshots where snapshot.generation == generation {
      snapshot.view.removeFromSuperview()
    }
    disappearingSnapshots.removeAll { $0.generation == generation }
  }

  func cancelTransitions() {
    layer.removeAllAnimations()
    for view in nodeViews.values {
      view.layer.removeAllAnimations()
      view.alpha = 1
      view.transform = .identity
    }
    for snapshot in disappearingSnapshots {
      snapshot.view.removeFromSuperview()
    }
    disappearingSnapshots.removeAll(keepingCapacity: true)
  }

  func prepareForReuse() {
    for view in nodeViews.values {
      enqueue(view)
    }
    nodeViews.removeAll(keepingCapacity: true)
    for snapshot in disappearingSnapshots {
      snapshot.view.removeFromSuperview()
    }
    disappearingSnapshots.removeAll(keepingCapacity: true)
    previousContent = nil
    currentPlan = nil
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard bounds.contains(point), var view = hitTest(point, with: nil) else { return nil }
    while view !== self {
      if let entityView = view as? RichBlockEntityHittableV2 {
        return entityView.entityHit(at: convert(point, to: view))
      }
      guard let parent = view.superview else { return nil }
      view = parent
    }
    return nil
  }

  var primaryTextSurface: UITextView? {
    guard let currentPlan else { return nil }
    for node in currentPlan.nodes {
      if let provider = nodeViews[node.path] as? RichBlockTextSurfaceProvidingV2 {
        return provider.textSurface
      }
    }
    return nil
  }

  func sourceView(forRichPhotoID photoID: Int64) -> UIView? {
    for view in nodeViews.values {
      if let image = view as? RichBlockImageNodeViewV2,
         let source = image.sourceView(forPhotoID: photoID)
      {
        return source
      }
      if let album = view as? RichBlockAlbumNodeViewV2,
         let source = album.sourceView(forPhotoID: photoID)
      {
        return source
      }
    }
    return nil
  }

  private func insertNodeView(_ view: RichBlockRenderableViewV2, for node: RichBlockLayoutPlanV2.Node) {
    if node.reuseKind == .quote {
      insertSubview(view, at: 0)
    } else {
      addSubview(view)
    }
  }

  private func retainRemovalSnapshot(of view: UIView, generation: UInt) {
    guard let snapshot = view.snapshotView(afterScreenUpdates: false),
          view.frame.width > 0,
          view.frame.height > 0
    else { return }
    snapshot.frame = view.layer.presentation()?.frame ?? view.frame
    snapshot.isUserInteractionEnabled = false
    addSubview(snapshot)
    disappearingSnapshots.append(.init(generation: generation, view: snapshot))
  }

  private func dequeue(kind: RichBlockRenderKindV2) -> RichBlockRenderableViewV2 {
    if var views = reusePool[kind], let view = views.popLast() {
      reusePool[kind] = views
      return view
    }
    return switch kind {
      case .text: RichBlockTextNodeViewV2()
      case .listMarker: RichBlockListMarkerNodeViewV2()
      case .disclosure: RichBlockDisclosureNodeViewV2()
      case .code: RichBlockCodeNodeViewV2()
      case .separator: RichBlockSeparatorNodeViewV2()
      case .image: RichBlockImageNodeViewV2()
      case .album: RichBlockAlbumNodeViewV2()
      case .quote: RichBlockQuoteNodeViewV2()
      case .table: RichBlockTableNodeViewV2()
    }
  }

  private func enqueue(_ view: RichBlockRenderableViewV2) {
    view.prepareForReuse()
    view.removeFromSuperview()
    var views = reusePool[view.reuseKind, default: []]
    if views.count < 16 { views.append(view) }
    reusePool[view.reuseKind] = views
  }
}
