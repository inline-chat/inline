import AppKit
import InlineSyntaxHighlighting

final class RichBlockCodeNodeView: RichBlockRenderableView {
  private let languageLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 10, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private let copyButton: NSButton = {
    let button = NSButton(title: "", target: nil, action: nil)
    button.bezelStyle = .inline
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.image = NSImage(
      systemSymbolName: "doc.on.doc",
      accessibilityDescription: "Copy code"
    )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    button.toolTip = "Copy code"
    button.setAccessibilityLabel("Copy code")
    return button
  }()

  private let gutter = RichBlockCodeGutterView(frame: .zero)
  private let surface = RichBlockTextSurface(frame: .zero)
  private let highlighter = CodeSyntaxHighlighter()
  private var rawText = ""
  private var gutterWidth: CGFloat = 0
  private var highlightGeneration: UInt64 = 0
  private var highlightTask: Task<Void, Never>?
  private var copyFeedbackTask: Task<Void, Never>?
  private var highlightInput: HighlightInput?
  private var renderSignature: RenderSignature?

  override var orderedTextSurfaces: [RichBlockTextSurface] { [surface] }

  private struct HighlightInput {
    let baseText: NSAttributedString
    let language: String?
    let palette: RichBlockPalette
    let linkColor: NSColor
    let onEntityClick: (MessageTextEntityHit, NSAttributedString) -> Bool
  }

  private struct RenderSignature: Equatable {
    let text: NSAttributedString
    let language: String?
    let presentation: RichBlockCodePresentation
    let baseFontSize: CGFloat
    let gutterWidth: CGFloat
    let lineCount: Int
    let primary: ResolvedColor
    let secondary: ResolvedColor
    let tertiary: ResolvedColor
    let link: ResolvedColor
    let codeFill: ResolvedColor

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.text.isEqual(to: rhs.text)
        && lhs.language == rhs.language
        && lhs.presentation == rhs.presentation
        && lhs.baseFontSize == rhs.baseFontSize
        && lhs.gutterWidth == rhs.gutterWidth
        && lhs.lineCount == rhs.lineCount
        && lhs.primary == rhs.primary
        && lhs.secondary == rhs.secondary
        && lhs.tertiary == rhs.tertiary
        && lhs.link == rhs.link
        && lhs.codeFill == rhs.codeFill
    }
  }

  /// Theme colors are dynamic and recreated on access. Compare their resolved
  /// components so equivalent palettes still hit the render cache.
  private struct ResolvedColor: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ color: NSColor) {
      let resolved = color.usingColorSpace(.deviceRGB) ?? color
      red = resolved.redComponent
      green = resolved.greenComponent
      blue = resolved.blueComponent
      alpha = resolved.alphaComponent
    }
  }

  init() {
    super.init(reuseKind: .code)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.masksToBounds = true
    copyButton.target = self
    copyButton.action = #selector(copyCode)
    addSubview(languageLabel)
    addSubview(copyButton)
    addSubview(gutter)
    addSubview(surface)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .code(code) = node.kind else { return }
    let text = context.codeText(for: code)
    let signature = RenderSignature(
      text: text,
      language: code.language,
      presentation: context.codePresentation,
      baseFontSize: context.baseFontSize,
      gutterWidth: code.gutterWidth,
      lineCount: code.lineCount,
      primary: ResolvedColor(context.palette.primary),
      secondary: ResolvedColor(context.palette.secondary),
      tertiary: ResolvedColor(context.palette.tertiary),
      link: ResolvedColor(context.palette.link),
      codeFill: ResolvedColor(context.palette.codeFill)
    )
    if renderSignature == signature {
      surface.updateInteraction(context.interactions.onTextEntityClick)
      return
    }
    renderSignature = signature
    highlightGeneration &+= 1
    highlightTask?.cancel()
    highlightTask = nil
    highlightInput = nil
    rawText = text.string
    let showsGutter = context.codePresentation == .syntaxHighlighted
      && CodeSyntaxHighlighter.supports(language: code.language)
    gutterWidth = showsGutter ? code.gutterWidth : 0
    gutter.isHidden = !showsGutter
    languageLabel.stringValue = code.language.map(RichBlockCodeMetrics.displayLanguage) ?? ""
    languageLabel.isHidden = code.language == nil
    languageLabel.textColor = context.palette.secondary
    copyButton.contentTintColor = context.palette.secondary
    layer?.backgroundColor = context.palette.codeFill.cgColor
    gutter.apply(
      lineCount: code.lineCount,
      font: RichBlockCodeMetrics.gutterFont,
      color: context.palette.tertiary
    )
    surface.apply(
      text: text,
      linkColor: context.palette.link,
      onEntityClick: context.interactions.onTextEntityClick
    )
    if context.codePresentation == .syntaxHighlighted {
      highlightInput = .init(
        baseText: text,
        language: code.language,
        palette: context.palette,
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    }
    requestHighlightIfNeeded()
    needsLayout = true
  }

  override func setContentVisible(_ visible: Bool) {
    super.setContentVisible(visible)
    if visible {
      requestHighlightIfNeeded()
    } else {
      highlightTask?.cancel()
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
    highlightInput = nil
    renderSignature = nil
  }

  override func layout() {
    super.layout()
    let hasLanguage = !languageLabel.isHidden
    languageLabel.frame = CGRect(
      x: RichBlockCodeMetrics.horizontalInset,
      y: RichBlockCodeMetrics.headerControlTopInset,
      width: max(0, bounds.width - 80),
      height: RichBlockCodeMetrics.headerControlHeight
    )
    let copyButtonSize = CGSize(width: 16, height: 16)
    let copyY: CGFloat = if hasLanguage {
      max(
        RichBlockCodeMetrics.headerControlTopInset,
        floor((RichBlockCodeMetrics.languageHeaderHeight - copyButtonSize.height) / 2) + 1
      )
    } else {
      4
    }
    copyButton.frame = CGRect(
      x: max(
        RichBlockCodeMetrics.horizontalInset,
        bounds.width - copyButtonSize.width - RichBlockCodeMetrics.horizontalInset
      ),
      y: copyY,
      width: copyButtonSize.width,
      height: copyButtonSize.height
    )
    let bodyY = RichBlockCodeMetrics.headerHeight(hasLanguage: hasLanguage)
      + RichBlockCodeMetrics.bodyTopInset(hasLanguage: hasLanguage)
    let bodyHeight = max(0, bounds.height - bodyY - RichBlockCodeMetrics.bodyBottomInset)
    gutter.frame = CGRect(
      x: RichBlockCodeMetrics.horizontalInset,
      y: bodyY,
      width: gutterWidth,
      height: bodyHeight
    )
    surface.frame = CGRect(
      x: RichBlockCodeMetrics.horizontalInset
        + gutterWidth
        + (gutterWidth > 0 ? RichBlockCodeMetrics.gutterContentGap : 0),
      y: bodyY,
      width: RichBlockCodeMetrics.bodyWidth(containerWidth: bounds.width, gutterWidth: gutterWidth),
      height: bodyHeight
    )
    surface.layoutSubtreeIfNeeded()
    gutter.setLineFragments(surface.logicalLineFragments())
  }

  @objc private func copyCode() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(rawText, forType: .string) else { return }
    copyFeedbackTask?.cancel()
    setCopyFeedback(copied: true)
    copyFeedbackTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      guard !Task.isCancelled else { return }
      self?.setCopyFeedback(copied: false)
    }
  }

  private func setCopyFeedback(copied: Bool) {
    let symbolName = copied ? "checkmark" : "doc.on.doc"
    let label = copied ? "Copied" : "Copy code"
    copyButton.image = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: label
    )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
    copyButton.toolTip = label
    copyButton.setAccessibilityLabel(label)
  }

  private func requestHighlightIfNeeded() {
    highlightGeneration &+= 1
    let generation = highlightGeneration
    highlightTask?.cancel()
    guard isContentVisible,
          let input = highlightInput,
          CodeSyntaxHighlighter.supports(language: input.language)
    else { return }
    let highlighter = highlighter
    let rawText = input.baseText.string
    highlightTask = Task { [weak self] in
      guard let tokens = try? await highlighter.tokens(for: rawText, language: input.language),
            !Task.isCancelled,
            let self,
            self.highlightGeneration == generation,
            self.rawText == rawText
      else { return }
      let highlighted = NSMutableAttributedString(attributedString: input.baseText)
      let fullLength = highlighted.length
      for token in tokens where token.range.location >= 0
        && token.range.location <= fullLength
        && token.range.length <= fullLength - token.range.location
      {
        highlighted.addAttribute(
          .foregroundColor,
          value: tokenColor(token.kind, palette: input.palette),
          range: token.range
        )
      }
      surface.apply(
        text: highlighted,
        linkColor: input.linkColor,
        onEntityClick: input.onEntityClick
      )
      needsLayout = true
    }
  }

  private func tokenColor(_ kind: CodeTokenKind, palette: RichBlockPalette) -> NSColor {
    switch kind {
    case .keyword, .number, .constant:
      palette.link
    case .type:
      palette.link.blended(withFraction: 0.28, of: palette.primary) ?? palette.link
    case .function, .property, .operatorSymbol:
      palette.primary
    case .string:
      palette.secondary
    case .comment:
      palette.secondary.withAlphaComponent(0.72)
    case .punctuation:
      palette.secondary
    }
  }
}

private final class RichBlockCodeGutterView: NSView {
  private var lineCount = 0
  private var font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
  private var color = NSColor.secondaryLabelColor
  private var fragments: [(number: Int, y: CGFloat, height: CGFloat)] = []

  override var isFlipped: Bool { true }

  func apply(lineCount: Int, font: NSFont, color: NSColor) {
    self.lineCount = lineCount
    self.font = font
    self.color = color
    needsDisplay = true
  }

  func setLineFragments(_ fragments: [(number: Int, y: CGFloat, height: CGFloat)]) {
    self.fragments = fragments
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
    ]
    let visibleFragments = fragments.isEmpty
      ? (1 ... max(lineCount, 1)).map { ($0, CGFloat($0 - 1) * ceil(font.ascender - font.descender + font.leading), ceil(font.ascender - font.descender + font.leading)) }
      : fragments.map { ($0.number, $0.y, $0.height) }
    for fragment in visibleFragments {
      let value = "\(fragment.0)" as NSString
      let size = value.size(withAttributes: attributes)
      value.draw(
        at: CGPoint(
          x: max(0, bounds.width - size.width - RichBlockCodeMetrics.gutterTextTrailingInset),
          y: fragment.1 + floor((fragment.2 - size.height) / 2)
        ),
        withAttributes: attributes
      )
    }
  }
}
