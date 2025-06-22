import AppKit
import InlineKit
import Logger

class ComposeTextEditor: NSView {
  // MARK: - Internals

  public let scrollView: ComposeScrollView
  public let textView: ComposeNSTextView
  private let log = Log.scoped("ComposeTextEditor", enableTracing: false)

  // MARK: - Theme

  static let font: NSFont = .preferredFont(forTextStyle: .body)
  private var font: NSFont { Self.font }

  static let textColor: NSColor = .labelColor
  private var textColor: NSColor { Self.textColor }

  static let linkColor: NSColor = .linkColor
  private var linkColor: NSColor { Self.linkColor }

  let minHeight: CGFloat = Theme.composeMinHeight
  let minTextHeight: CGFloat = Theme.composeMinHeight - 2 * Theme.composeVerticalPadding
  let verticalPadding: CGFloat = Theme.composeVerticalPadding
  let horizontalPadding: CGFloat = Theme.composeTextViewHorizontalPadding

  // MARK: - Computed

  weak var delegate: (NSTextViewDelegate & ComposeTextViewDelegate)? {
    didSet {
      textView.delegate = delegate
    }
  }

  var string: String {
    get { textView.string }
    set {
      let selectedRanges = textView.selectedRanges
      textView.string = newValue
      textView.selectedRanges = selectedRanges
    }
  }

  var attributedString: NSAttributedString {
    textView.attributedString()
  }

  // MARK: - Methods

//  func setAttributedString(_ attributedString: NSAttributedString) {
//    textView.setAttributedText(attributedString, preserveSelection: true)
//  }

  // Does not preserve selection
  func replaceAttributedString(_ attributedString: NSAttributedString) {
    textView.setAttributedText(attributedString, preserveSelection: false)
  }

  private lazy var paragraphStyle = {
    let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
    paragraph.lineSpacing = 0.0
    paragraph.baseWritingDirection = .natural
    return paragraph
  }()

  private lazy var placeholder: NSTextField = {
    let label = NSTextField(labelWithString: "Message")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = Theme.messageTextFont
    label.lineBreakMode = .byTruncatingTail
    label.textColor = .placeholderTextColor
    return label
  }()

  var initiallySingleLine: Bool

  init(initiallySingleLine: Bool = false) {
    scrollView = ComposeScrollView()
    textView = ComposeNSTextView()

    self.initiallySingleLine = initiallySingleLine

    super.init(frame: .zero)

    setupViews()
    setupConstraints()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    // Scroll view
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalRuler = false
    scrollView.scrollerStyle = .overlay
    scrollView.autoresizingMask = [.width]
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentInsets = NSEdgeInsets(top: verticalPadding, left: 8, bottom: verticalPadding, right: 8)
    scrollView.verticalScrollElasticity = .none
    addSubview(scrollView)

    // Text view
    textView.drawsBackground = false
    textView.font = font
    textView.backgroundColor = .clear
    textView.textColor = .labelColor
    textView.allowsUndo = true
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.isHorizontallyResizable = false
    textView.isAutomaticLinkDetectionEnabled = true

    // Enables paste command for NSImages from clipboard
    textView.importsGraphics = true

    // Must be called after import graphics as that enables it
    // textView.isRichText = false
    textView.isRichText = true

    // Smart
    textView.isAutomaticTextCompletionEnabled = true

    // Optional: Enable other smart features
    textView.isContinuousSpellCheckingEnabled = true
    textView.isGrammarCheckingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = true
    textView.isAutomaticDashSubstitutionEnabled = true

    textView.typingAttributes = [
      .paragraphStyle: paragraphStyle,
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ]

    if !initiallySingleLine {
      let lineHeight = calculateLineHeight()
      textView.textContainerInset = NSSize(
        width: 0,
        height: (minHeight - lineHeight) / 2
      )
    } else {
      textView.textContainerInset = NSSize(
        width: 0,
        height: verticalPadding
      )
    }

    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = horizontalPadding

    textView.delegate = delegate

    // Hook it up
    scrollView.documentView = textView
  }

  private var heightConstraint: NSLayoutConstraint!

  private func setupConstraints() {
    heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: minHeight)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      heightConstraint, // don't anchor to bottom
    ])
  }

  private func calculateLineHeight() -> CGFloat {
    let lineHeightMultiple = paragraphStyle.lineHeightMultiple.isAlmostZero() ? 1.0 : paragraphStyle.lineHeightMultiple
    return (font.ascender - font.descender + font.leading) * lineHeightMultiple
  }

  func setHeight(_ height: CGFloat) {
    heightConstraint.constant = height
  }

  func setHeightAnimated(_ height: CGFloat) {
    heightConstraint.animator().constant = height
  }

  var initialPlaceholderPosition: CGPoint? = nil
  var isPlaceholderVisible: Bool = true

  func showPlaceholder(_ show: Bool) {
    if show {
      addSubview(placeholder)

      NSLayoutConstraint.activate([
        placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
        placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
        placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    if initialPlaceholderPosition == nil {
      initialPlaceholderPosition = placeholder.layer?.position
    }

    let initialPosition = initialPlaceholderPosition ?? .zero

    guard isPlaceholderVisible != show else { return }

    isPlaceholderVisible = show

    let offsetX = 15.0
    let offsetY = 0.0

    CATransaction.begin()
    
    CATransaction.setCompletionBlock {
      if !show {
        self.placeholder.removeFromSuperview()
      }
    }
    
    let animationGroup = CAAnimationGroup()
    animationGroup.duration = show ? 0.2 : 0.1
    animationGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    

    let fade = CABasicAnimation(keyPath: "opacity")
    if show {
      fade.fromValue = 0.0
      fade.toValue = 1.0
    } else {
      fade.fromValue = 1.0
      fade.toValue = 0.0
    }

    let move = CABasicAnimation(keyPath: "position")
    let endPosition: CGPoint?
    if show {
      move.fromValue = CGPoint(
        x: initialPosition.x + offsetX,
        y: initialPosition.y + offsetY
      )
      endPosition = initialPosition
      move.toValue = endPosition
    } else {
      endPosition = CGPoint(
        x: initialPosition.x + offsetX,
        y: initialPosition.y + offsetY
      )
      move.fromValue = initialPosition
      move.toValue = endPosition
    }

    animationGroup.animations = [fade, move]

    // Update the actual properties to match final state
    placeholder.alphaValue = show ? 1 : 0
    placeholder.layer?.position = endPosition ?? .zero

    placeholder.layer?.add(animationGroup, forKey: nil)
    CATransaction.commit()
    
  }

  func getTypingLineHeight() -> CGFloat {
    let lineHeightMultiple = paragraphStyle.lineHeightMultiple.isAlmostZero() ? 1.0 : paragraphStyle.lineHeightMultiple
    return calculateDefaultLineHeight(for: font) * lineHeightMultiple
  }

  func focus() {
    window?.makeFirstResponder(textView)
  }

  func clear() {
    let emptyAttributedString = createEmptyAttributedString()
    textView.setAttributedText(emptyAttributedString, preserveSelection: false)
    showPlaceholder(true)
  }

  public func setString(_ string: String) {
    let attributedString = createAttributedString(string)
    textView.setAttributedText(attributedString, preserveSelection: false)
    if string.isEmpty {
      showPlaceholder(true)
    } else {
      showPlaceholder(false)
    }
  }

  public func setAttributedString(_ attributedString: NSAttributedString) {
    textView.setAttributedText(attributedString, preserveSelection: false)
    if string.isEmpty {
      showPlaceholder(true)
    } else {
      showPlaceholder(false)
    }
  }

  func insertText(_ text: String) {
    // Ensure proper typing attributes before inserting text
    textView.updateTypingAttributesIfNeeded()
    textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  func resetTextViewInsets() {
    if initiallySingleLine {
      textView.textContainerInset = NSSize(
        width: 0,
        height: verticalPadding
      )
    } else {
      let lineHeight = getTypingLineHeight()
      textView.textContainerInset = NSSize(
        width: 0,
        height: (minHeight - lineHeight) / 2
      )
    }
  }

  func updateTextViewInsets(contentHeight: CGFloat) {
    if initiallySingleLine {
      textView.textContainerInset = NSSize(
        width: 0,
        height: verticalPadding
      )
      return
    }

    let lineHeight = getTypingLineHeight()
    let newInsets = NSSize(
      width: 0,
      height: contentHeight <= lineHeight ?
        (minHeight - lineHeight) / 2 :
        verticalPadding
    )
    log.debug("Updating text view insets: \(newInsets)")

    textView.textContainerInset = newInsets

    // Hack to update caret position
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let currentRange = textView.selectedRange
      textView.selectedRange = NSMakeRange(currentRange.location, 0)
      textView.setNeedsDisplay(textView.bounds)
    }
  }
}

// MARK: - NSTextView Extensions for Attributed String Helpers

extension NSTextView {
  /// Default attributes for this text view
  var defaultTypingAttributes: [NSAttributedString.Key: Any] {
    [
      .font: font ?? NSFont.preferredFont(forTextStyle: .body),
      .foregroundColor: NSColor.labelColor,
    ]
  }

  /// Check if cursor is positioned after a mention
  var isCursorAfterMention: Bool {
    let selectedRange = selectedRange()
    guard selectedRange.length == 0, selectedRange.location > 0 else { return false }

    let checkPosition = selectedRange.location - 1
    let attributes = attributedString().attributes(at: checkPosition, effectiveRange: nil)
    return attributes[.mentionUserId] != nil
  }

  /// Check if current typing attributes have mention styling
  var hasTypingAttributesMentionStyling: Bool {
    let currentTypingAttributes = typingAttributes
    return currentTypingAttributes[.mentionUserId] != nil ||
      (currentTypingAttributes[.foregroundColor] as? NSColor) == NSColor.systemBlue
  }

  /// Reset typing attributes to default to prevent mention style leakage
  func resetTypingAttributesToDefault() {
    typingAttributes = defaultTypingAttributes
  }

  /// Update typing attributes based on cursor position to prevent style leakage
  func updateTypingAttributesIfNeeded() {
    let selectedRange = selectedRange()

    // If cursor is after a mention or typing attributes have mention styling, reset to default
    if selectedRange.length == 0, isCursorAfterMention || hasTypingAttributesMentionStyling {
      resetTypingAttributesToDefault()
    }
  }

  /// Set attributed text while preserving selection
  func setAttributedText(_ attributedString: NSAttributedString, preserveSelection: Bool = true) {
    let selectedRanges = preserveSelection ? selectedRanges : []
    textStorage?.setAttributedString(attributedString)
    if preserveSelection {
      self.selectedRanges = selectedRanges
    }
  }
}

// MARK: - ComposeTextEditor Extensions

extension ComposeTextEditor {
  /// Create attributed string using this editor's font
  func createAttributedString(_ text: String) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ])
  }

  /// Create empty attributed string using this editor's font
  func createEmptyAttributedString() -> NSAttributedString {
    NSAttributedString(string: "", attributes: [
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ])
  }

  /// Check if the attributed text in this editor is empty
  var isAttributedTextEmpty: Bool {
    attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Get plain text from this editor's attributed string
  var plainText: String {
    attributedString.string
  }
}
