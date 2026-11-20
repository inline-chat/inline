import AppKit
import InlineKit
import Logger
import MacTheme
import TextProcessing

class ComposeTextEditor: NSView {
  // MARK: - Internals

  public let scrollView: ComposeScrollView
  public let textView: ComposeNSTextView
  private let log = Log.scoped("ComposeTextEditor")
  private let mode: ComposeControlMode

  // MARK: - Theme

  /// The chat's message font, so a draft reads like the message it becomes.
  static var font: NSFont { ChatTypography.current.font }
  private var font: NSFont { Self.font }

  /// Inline code and code blocks, at the size messages draw inline code.
  static var codeFont: NSFont {
    let typography = ChatTypography.current
    return typography.codeFont(sized: ChatTypography.inlineCodePointSize(at: typography.pointSize))
  }

  /// Called after a typography change restyles the editor, so its owner can
  /// re-measure the compose height.
  var onTypographyDidChange: (() -> Void)?
  nonisolated(unsafe) private var typographyObserver: NSObjectProtocol?

  static let textColor: NSColor = .labelColor
  private var textColor: NSColor { Self.textColor }

  static let linkColor: NSColor = .linkColor
  private var linkColor: NSColor { Self.linkColor }

  var minHeight: CGFloat { mode.textMinHeight }
  var minTextHeight: CGFloat { mode.textMinHeight - 2 * Theme.composeVerticalPadding }
  // Legacy multiline text needs breathing room once it outgrows the centered
  // single-line row. Its height calculation uses this same inset.
  var verticalPadding: CGFloat {
    mode.usesInputStyleTextInsets ? Theme.composeVerticalPadding : 8
  }
  let horizontalPadding: CGFloat = Theme.composeTextViewHorizontalPadding
  private var usesInputStyleTextInsets: Bool {
    initiallySingleLine || mode.usesInputStyleTextInsets
  }

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
    let normalized = normalizeParagraphStyle(in: attributedString)
    textView.setAttributedText(normalized, preserveSelection: false)
    // Reset typing attributes if string is empty to prevent formatting carryover
    if normalized.string.isEmpty {
      textView.typingAttributes = [
        .paragraphStyle: paragraphStyle,
        .font: font,
        .foregroundColor: textColor,
        .underlineStyle: 0,
      ]
    }
  }

  static func makeParagraphStyle(from existing: NSParagraphStyle? = nil) -> NSParagraphStyle {
    let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle)
      ?? (NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle)
    // Lines advance like message text, so a multiline draft keeps its shape when sent.
    paragraph.lineSpacing = ChatTypography.current.lineSpacing
    paragraph.alignment = .natural
    paragraph.baseWritingDirection = .natural
    return paragraph.copy() as! NSParagraphStyle
  }

  static var defaultParagraphStyle: NSParagraphStyle {
    makeParagraphStyle()
  }

  private lazy var paragraphStyle = Self.defaultParagraphStyle

  var placeholderText: String = "Message" {
    didSet {
      guard placeholderText != oldValue else { return }
      updatePlaceholderContent()
    }
  }

  var placeholderSymbolName: String? {
    didSet {
      guard placeholderSymbolName != oldValue else { return }
      updatePlaceholderContent()
    }
  }

  /// A suggested next message, shown in place of the placeholder with a Tab
  /// key hint while the editor is empty.
  var suggestionText: String? {
    didSet {
      guard suggestionText != oldValue else { return }
      updatePlaceholderContent()
    }
  }

  private func updatePlaceholderContent() {
    placeholder.text = suggestionText ?? placeholderText
    placeholder.symbolName = suggestionText == nil ? placeholderSymbolName : nil
    placeholder.showsKeyHint = suggestionText != nil
    textView.setAccessibilityPlaceholderValue(suggestionText.map { "\($0), press Tab to use" } ?? placeholderText)
  }

  private lazy var placeholder = ComposePlaceholderView(
    text: placeholderText,
    symbolName: placeholderSymbolName
  )

  var initiallySingleLine: Bool

  init(initiallySingleLine: Bool = false, mode: ComposeControlMode = .legacy) {
    scrollView = ComposeScrollView()
    textView = Self.makeTextView()

    self.mode = mode
    self.initiallySingleLine = initiallySingleLine

    super.init(frame: .zero)

    setupViews()
    setupConstraints()
    typographyObserver = NotificationCenter.default.addObserver(
      forName: ChatTypography.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyCurrentTypography() }
    }
  }

  deinit {
    if let typographyObserver {
      NotificationCenter.default.removeObserver(typographyObserver)
    }
  }

  /// Restyles the draft in place for the current chat typography: body runs take
  /// the new font (keeping bold and italic), code runs the code font, and every
  /// paragraph the new line spacing. Text, selection and undo history are untouched.
  func applyCurrentTypography() {
    paragraphStyle = Self.defaultParagraphStyle
    placeholder.font = font
    if let storage = textView.textStorage, storage.length > 0 {
      let fullRange = NSRange(location: 0, length: storage.length)
      storage.beginEditing()
      var fonts: [(NSRange, NSFont)] = []
      storage.enumerateAttribute(.font, in: fullRange) { value, range, _ in
        fonts.append((range, Self.restyled(value as? NSFont, attributes: storage.attributes(at: range.location, effectiveRange: nil))))
      }
      for (range, font) in fonts {
        storage.addAttribute(.font, value: font, range: range)
      }
      var styles: [(NSRange, NSParagraphStyle)] = []
      storage.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
        styles.append((range, Self.makeParagraphStyle(from: value as? NSParagraphStyle)))
      }
      for (range, style) in styles {
        storage.addAttribute(.paragraphStyle, value: style, range: range)
      }
      storage.endEditing()
    }
    var typing = textView.typingAttributes
    typing[.font] = Self.restyled(typing[.font] as? NSFont, attributes: typing)
    typing[.paragraphStyle] = Self.makeParagraphStyle(from: typing[.paragraphStyle] as? NSParagraphStyle)
    textView.typingAttributes = typing
    resetTextViewInsets()
    onTypographyDidChange?()
  }

  /// `font` from a run with `attributes`, moved to the current chat typography.
  private static func restyled(_ font: NSFont?, attributes: [NSAttributedString.Key: Any]) -> NSFont {
    let isCode = attributes[.inlineCode] != nil || attributes[.preCode] != nil
      || font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
    if isCode { return codeFont }
    var result = Self.font
    let traits = font?.fontDescriptor.symbolicTraits ?? []
    if traits.contains(.bold) {
      result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
    }
    if traits.contains(.italic) {
      result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
    }
    return result
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    // Scroll view
    scrollView.drawsBackground = false
    // Glass divergence: the glass compose is a compact input-style field, so
    // do not show a persistent editor scroller for the normal one-line state.
    scrollView.hasVerticalScroller = !mode.usesInputStyleTextInsets
    scrollView.hasHorizontalRuler = false
    scrollView.scrollerStyle = .overlay
    scrollView.autoresizingMask = [.width]
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentInsets = mode.usesInputStyleTextInsets
      ? NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
      : NSEdgeInsets(top: Theme.composeVerticalPadding, left: 8, bottom: Theme.composeVerticalPadding, right: 8)
    scrollView.verticalScrollElasticity = .none
    addSubview(scrollView)

    // Text view
    textView.drawsBackground = false
    textView.font = font
    textView.backgroundColor = .clear
    textView.textColor = .labelColor
    textView.alignment = .natural
    textView.allowsUndo = true
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.isHorizontallyResizable = false
    // TODO(@Mo): Replace AppKit automatic link detection with Inline link detection so compose never shows
    // data-detector styling for non-URL content (phone numbers, dates, etc).
    textView.isAutomaticLinkDetectionEnabled = true
    // We don't underline links (including in compose).
    textView.linkTextAttributes = [
      .foregroundColor: linkColor,
      .underlineStyle: 0,
    ]

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
    textView.isAutomaticDashSubstitutionEnabled = false

    textView.typingAttributes = [
      .paragraphStyle: paragraphStyle,
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ]

    if usesInputStyleTextInsets {
      textView.textContainerInset = NSSize(
        width: 0,
        height: inputStyleTextInsetHeight()
      )
    } else {
      let lineHeight = calculateLineHeight()
      textView.textContainerInset = NSSize(
        width: 0,
        height: (minHeight - lineHeight) / 2
      )
    }

    configureTextContainer()
    let hasTextKit2 = textView.textLayoutManager != nil
    log.trace("Compose text engine: textKit2=\(hasTextKit2), textKit1LayoutManager=\(textView.layoutManager != nil)")
    if !hasTextKit2 {
      log.error("Compose text view is not using TextKit 2")
    }

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

  private func configureTextContainer() {
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = horizontalPadding
  }

  private static func makeTextView() -> ComposeNSTextView {
    ComposeNSTextView(usingTextLayoutManager: true)
  }

  func setHeight(_ height: CGFloat) {
    heightConstraint.constant = height
  }

  func setHeightAnimated(_ height: CGFloat) {
    heightConstraint.animator().constant = height
  }

  var isPlaceholderVisible: Bool = false

  func showPlaceholder(_ show: Bool) {
    if isPlaceholderVisible == show, !(show && placeholder.superview == nil) { return }
    isPlaceholderVisible = show

    if placeholder.superview == nil {
      guard show else { return }
      placeholder.alphaValue = 0
      addSubview(placeholder)
      NSLayoutConstraint.activate([
        placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
        placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
        placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
      layoutSubtreeIfNeeded()
    }

    // Animate an offset from AppKit's current layout position, never a cached
    // absolute position. Keeping the view attached also avoids removal races.
    let layer = placeholder.layer
    let presentation = layer?.presentation()
    let opacity = presentation?.opacity ?? Float(placeholder.alphaValue)
    let offset: CGFloat
    if opacity > 0, let layer, let presentation {
      offset = presentation.position.x - layer.position.x
    } else {
      offset = show ? 15 : 0
    }

    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = opacity
    fade.toValue = show ? 1.0 : 0.0

    let move = CABasicAnimation(keyPath: "position.x")
    move.isAdditive = true
    move.fromValue = offset
    move.toValue = show ? 0.0 : 15.0

    let animation = CAAnimationGroup()
    animation.animations = [fade, move]
    animation.duration = show ? 0.2 : 0.1
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    placeholder.alphaValue = show ? 1 : 0
    layer?.add(animation, forKey: "placeholderVisibility")
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
    replaceAttributedString(emptyAttributedString)
    resetFormattingState()
    showPlaceholder(true)
  }

  public func setString(_ string: String) {
    let attributedString = createAttributedString(string)
    replaceAttributedString(attributedString)
    if string.isEmpty {
      showPlaceholder(true)
    } else {
      showPlaceholder(false)
    }
  }

  public func setAttributedString(_ attributedString: NSAttributedString) {
    replaceAttributedString(attributedString)
    if attributedString.string.isEmpty {
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
    if usesInputStyleTextInsets {
      textView.textContainerInset = NSSize(
        width: 0,
        height: inputStyleTextInsetHeight()
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
    if usesInputStyleTextInsets {
      textView.textContainerInset = NSSize(
        width: 0,
        height: inputStyleTextInsetHeight()
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
    log.trace("Updating text view insets: \(newInsets)")

    textView.textContainerInset = newInsets

    // Hack to update caret position
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let currentRange = textView.selectedRange
      textView.selectedRange = NSMakeRange(currentRange.location, 0)
      textView.setNeedsDisplay(textView.bounds)
    }
  }

  private func inputStyleTextInsetHeight() -> CGFloat {
    // Glass divergence: fixed input-style inset keeps the first line centered
    // in the 34pt row without using legacy dynamic recentering on height changes.
    max(0, (minHeight - getTypingLineHeight()) / 2)
  }

  private func resetFormattingState() {
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.font = font
    textView.textColor = textColor
    textView.typingAttributes = [
      .paragraphStyle: paragraphStyle,
      .font: font,
      .foregroundColor: textColor,
      .underlineStyle: 0,
    ]
  }

  private func normalizeParagraphStyle(in attributedString: NSAttributedString) -> NSAttributedString {
    guard attributedString.length > 0 else { return attributedString }

    let mutable = NSMutableAttributedString(attributedString: attributedString)
    let text = mutable.string as NSString
    var location = 0

    while location < text.length {
      let range = text.paragraphRange(for: NSRange(location: location, length: 0))
      let existing = mutable.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
      let style = Self.makeParagraphStyle(from: existing)
      mutable.addAttribute(.paragraphStyle, value: style, range: range)
      location = NSMaxRange(range)
    }

    return mutable
  }
}

private final class ComposePlaceholderView: NSView {
  private let imageView = NSImageView()
  private let label: NonInteractiveTextField
  private let keyHint = ComposeKeyHintView(key: "Tab")
  private var imageWidthConstraint: NSLayoutConstraint!
  private var labelLeadingConstraint: NSLayoutConstraint!
  private var labelToEdge: NSLayoutConstraint!
  private var labelToHint: NSLayoutConstraint!

  var showsKeyHint = false {
    didSet {
      guard showsKeyHint != oldValue else { return }
      keyHint.isHidden = !showsKeyHint
      labelToEdge.isActive = !showsKeyHint
      labelToHint.isActive = showsKeyHint
    }
  }

  var text: String {
    didSet {
      guard text != oldValue else { return }
      label.stringValue = text
      label.invalidateIntrinsicContentSize()
    }
  }

  var symbolName: String? {
    didSet {
      guard symbolName != oldValue else { return }
      updateSymbol()
    }
  }

  var font: NSFont {
    get { label.font ?? ComposeTextEditor.font }
    set {
      label.font = newValue
      label.invalidateIntrinsicContentSize()
    }
  }

  init(text: String, symbolName: String?) {
    self.text = text
    self.symbolName = symbolName
    label = NonInteractiveTextField(label: text)
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleProportionallyDown
    imageView.contentTintColor = .placeholderTextColor
    imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    imageView.setAccessibilityElement(false)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = ComposeTextEditor.font
    label.lineBreakMode = .byTruncatingTail
    label.textColor = .placeholderTextColor
    label.isEditable = false
    label.isSelectable = false
    label.isEnabled = false

    addSubview(imageView)
    addSubview(label)
    addSubview(keyHint)
    keyHint.isHidden = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 16)
    labelLeadingConstraint = label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5)
    labelToEdge = label.trailingAnchor.constraint(equalTo: trailingAnchor)
    labelToHint = keyHint.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageWidthConstraint,
      imageView.heightAnchor.constraint(equalToConstant: 16),
      labelLeadingConstraint,
      labelToEdge,
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
      keyHint.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      keyHint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
    ])

    updateSymbol()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  private func updateSymbol() {
    let image = symbolName.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)
    }
    let hasSymbol = image != nil
    imageView.image = image
    imageView.isHidden = !hasSymbol
    imageWidthConstraint.constant = hasSymbol ? 16 : 0
    labelLeadingConstraint.constant = hasSymbol ? 5 : 0
  }
}

/// A small keycap ("Tab") after a suggested message, like other apps' hints.
private final class ComposeKeyHintView: NSView {
  private let label: NonInteractiveTextField

  init(key: String) {
    label = NonInteractiveTextField(label: key)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.borderWidth = 1
    setContentCompressionResistancePriority(.required, for: .horizontal)
    setContentHuggingPriority(.required, for: .horizontal)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 10, weight: .medium)
    label.textColor = .placeholderTextColor
    label.isEditable = false
    label.isSelectable = false
    label.isEnabled = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateLayer() {
    super.updateLayer()
    layer?.borderColor = NSColor.placeholderTextColor.withAlphaComponent(0.5).cgColor
  }

  override var wantsUpdateLayer: Bool { true }
}

// MARK: - NSTextView Extensions for Attributed String Helpers

extension NSTextView {
  var defaultParagraphStyle: NSParagraphStyle {
    let current = typingAttributes[.paragraphStyle] as? NSParagraphStyle
    return ComposeTextEditor.makeParagraphStyle(from: current)
  }

  /// Default attributes for this text view
  var defaultTypingAttributes: [NSAttributedString.Key: Any] {
    [
      .paragraphStyle: defaultParagraphStyle,
      // Use a stable base font instead of `self.font` (which can be mutated by the text system based on
      // selection/paste), otherwise resets can accidentally "lock in" monospace after pasting code blocks.
      .font: ComposeTextEditor.font,
      .foregroundColor: NSColor.labelColor,
      .underlineStyle: 0,
    ]
  }

  /// Check if cursor is positioned after a mention
  var isCursorAfterMention: Bool {
    let selectedRange = selectedRange()
    guard selectedRange.length == 0, selectedRange.location > 0 else { return false }

    let checkPosition = selectedRange.location - 1
    let attributes = attributedString().attributes(at: checkPosition, effectiveRange: nil)
    return attributes[.mentionUserId] != nil || attributes[.mentionGroupId] != nil
  }

  var isCursorAfterThreadLink: Bool {
    let selectedRange = selectedRange()
    guard selectedRange.length == 0, selectedRange.location > 0 else { return false }

    let checkPosition = selectedRange.location - 1
    let attributes = attributedString().attributes(at: checkPosition, effectiveRange: nil)
    return attributes[.threadLink] != nil
  }

  /// Check if current typing attributes have mention styling
  var hasTypingAttributesMentionStyling: Bool {
    let currentTypingAttributes = typingAttributes
    return currentTypingAttributes[.mentionUserId] != nil ||
      currentTypingAttributes[.mentionGroupId] != nil ||
      (currentTypingAttributes[.foregroundColor] as? NSColor) == NSColor.systemBlue
  }

  var hasTypingAttributesThreadLinkStyling: Bool {
    typingAttributes[.threadLink] != nil
  }

  /// Reset typing attributes to default to prevent mention style leakage
  func resetTypingAttributesToDefault() {
    var attributes = defaultTypingAttributes
    if let paragraphStyle = typingAttributes[.paragraphStyle] {
      attributes[.paragraphStyle] = paragraphStyle
    }
    attributes[.underlineStyle] = 0
    typingAttributes = attributes
  }

  private func resetLinkTypingAttributesIfNeeded() {
    let selection = selectedRange()
    guard typingAttributes[.link] != nil ||
      (typingAttributes[.foregroundColor] as? NSColor) == ComposeTextEditor.linkColor
    else { return }

    // Keep editing a surviving link's label, but never extend its formatting
    // past its boundaries or retain it after the linked text has been deleted
    // or typed over as a whole (e.g. Select All, then type).
    let text = attributedString()
    if selection.location < text.length, selection.location > 0 || selection.length > 0 {
      var linkRange = NSRange()
      let link = text.attribute(
        .link,
        at: selection.location,
        longestEffectiveRange: &linkRange,
        in: NSRange(location: 0, length: text.length)
      )
      if link != nil {
        if selection.length == 0, selection.location > linkRange.location { return }
        if selection.length > 0,
           NSIntersectionRange(linkRange, selection) == selection,
           linkRange != selection
        { return }
      }
    }

    var attributes = typingAttributes
    attributes.removeValue(forKey: .link)
    attributes.removeValue(forKey: .cursor)
    attributes[.foregroundColor] = ComposeTextEditor.textColor
    attributes[.underlineStyle] = attributes[.richTextUnderline] as? Bool == true
      ? NSUnderlineStyle.single.rawValue : 0
    typingAttributes = attributes
  }

  /// Update typing attributes based on cursor position to prevent style leakage
  func updateTypingAttributesIfNeeded() {
    let selectedRange = selectedRange()

    resetLinkTypingAttributesIfNeeded()

    // If cursor is after an entity or typing attributes have entity styling, reset to default.
    if selectedRange.length == 0,
       isCursorAfterMention || isCursorAfterThreadLink ||
       hasTypingAttributesMentionStyling || hasTypingAttributesThreadLinkStyling
    {
      resetTypingAttributesToDefault()
    }

    // Check if cursor is within a code block and maintain monospace font
    if selectedRange.length == 0,
       selectedRange.location > 0,
       selectedRange.location <= attributedString().length
    {
      let checkPosition = selectedRange.location - 1
      guard checkPosition >= 0, checkPosition < attributedString().length else { return }

      let attributes = attributedString().attributes(at: checkPosition, effectiveRange: nil)

      // Use shared utility to determine if we're in a code block
      if ProcessEntities.isCursorInCodeBlock(attributes: attributes) {
        updateTypingAttributesForCodeBlock(attributes: attributes)
      }
    }
  }

  /// Updates typing attributes to maintain monospace font for code blocks
  private func updateTypingAttributesForCodeBlock(attributes: [NSAttributedString.Key: Any]) {
    let monospaceFont = ComposeTextEditor.codeFont

    var newTypingAttributes = defaultTypingAttributes
    if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
      newTypingAttributes[.paragraphStyle] = ComposeTextEditor.makeParagraphStyle(from: paragraphStyle)
    }
    newTypingAttributes[.font] = monospaceFont

    // Preserve preCode or inlineCode attribute for continued typing
    if attributes[.preCode] != nil {
      newTypingAttributes[.preCode] = true
    } else if attributes[.inlineCode] != nil {
      newTypingAttributes[.inlineCode] = true
    }

    typingAttributes = newTypingAttributes
  }

  /// Set attributed text while preserving selection
  func setAttributedText(_ attributedString: NSAttributedString, preserveSelection: Bool = true) {
    (self as? ComposeNSTextView)?.resetPastedLinks()
    let selectedRanges = preserveSelection ? selectedRanges : []
    textStorage?.setAttributedString(attributedString)
    if preserveSelection {
      self.selectedRanges = selectedRanges
    }

    // Direct storage replacements bypass NSTextView's normal editing lifecycle.
    // Update the scrollable document now, including when loading a message to edit.
    needsLayout = true
    layoutSubtreeIfNeeded()
  }
}

// MARK: - ComposeTextEditor Extensions

extension ComposeTextEditor {
  /// Measures laid-out text height, including soft wraps and the extra line fragment.
  static func measuredContentHeight(for textView: NSTextView) -> CGFloat {
    if let textLayoutManager = textView.textLayoutManager {
      let documentEnd = textLayoutManager.documentRange.endLocation
      var fragmentMaxY: CGFloat = 0
      textLayoutManager.enumerateTextLayoutFragments(
        from: documentEnd,
        options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
      ) { fragment in
        fragmentMaxY = max(fragmentMaxY, fragment.layoutFragmentFrame.maxY)
        return false
      }

      let segmentRange = NSTextRange(location: documentEnd)
      textLayoutManager.ensureLayout(for: segmentRange)
      var segmentMaxY: CGFloat = 0
      textLayoutManager.enumerateTextSegments(
        in: segmentRange,
        type: .standard,
        options: .middleFragmentsExcluded
      ) { _, rect, _, _ in
        segmentMaxY = max(segmentMaxY, rect.maxY)
        return true
      }

      let measuredHeight = max(segmentMaxY, fragmentMaxY)
      if measuredHeight > 0 {
        return measuredHeight
      }

      let usageHeight = textLayoutManager.usageBoundsForTextContainer.height
      return usageHeight.isFinite ? usageHeight : 0
    }

    if let layoutManager = textView.layoutManager,
       let textContainer = textView.textContainer {
      layoutManager.ensureLayout(for: textContainer)
      return layoutManager.usedRect(for: textContainer).height
    }

    return 0
  }

  /// Create attributed string using this editor's font
  func createAttributedString(_ text: String) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
      .paragraphStyle: paragraphStyle,
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ])
  }

  /// Create empty attributed string using this editor's font
  func createEmptyAttributedString() -> NSAttributedString {
    NSAttributedString(string: "", attributes: [
      .paragraphStyle: paragraphStyle,
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ])
  }

  /// Check if the attributed text in this editor is empty
  var isAttributedTextEmpty: Bool {
    attributedString.string.isEmpty
  }

  /// Get plain text from this editor's attributed string
  var plainText: String {
    attributedString.string
  }
}
