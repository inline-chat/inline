import AppKit
import InlineKit

class ComposeTextEditor: NSView {
  public let scrollView: ComposeScrollView
  private let textView: ComposeNSTextView
  private let font: NSFont = .preferredFont(forTextStyle: .body)
  private let log = Log.scoped("ComposeTextEditor", enableTracing: false)
  let minHeight: CGFloat = Theme.composeMinHeight
  let minTextHeight: CGFloat = Theme.composeMinHeight - 2 * Theme.composeVerticalPadding
  private let horizontalPadding: CGFloat = 10.0
   let verticalPadding: CGFloat = Theme.composeVerticalPadding
    
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
  
  init() {
    self.scrollView = ComposeScrollView()
    self.textView = ComposeNSTextView()
  
    super.init(frame: .zero)
        
    setupViews()
    setupConstraints()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  private func setupViews() {
    addSubview(placeholder)
    
    // Scroll view
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalRuler = false
    scrollView.autoresizingMask = [.width]
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    scrollView.verticalScrollElasticity = .none
    addSubview(scrollView)
    
    // Text view
    textView.drawsBackground = false
    textView.isRichText = false
    textView.font = font
    textView.backgroundColor = .clear
    textView.textColor = .labelColor
    textView.allowsUndo = true
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.isHorizontallyResizable = false
    textView.isAutomaticLinkDetectionEnabled = true
    
    textView.typingAttributes = [
      .paragraphStyle: paragraphStyle,
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ]
    
    let lineHeight = calculateLineHeight()
    textView.textContainerInset = NSSize(
      width: 0,
      height: (minHeight - lineHeight) / 2
    )
    
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
      
      // placeholder
      placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
      placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
      placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
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
    if initialPlaceholderPosition == nil {
      initialPlaceholderPosition = placeholder.layer?.position
    }
    
    let initialPosition = initialPlaceholderPosition ?? .zero
    
    guard isPlaceholderVisible != show else { return }
    
    isPlaceholderVisible = show
    
    let offsetX = 15.0
    let offsetY = 0.0
  
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
      move.fromValue = CGPoint(x: initialPosition.x + offsetX,
                               y: initialPosition.y + offsetY)
      endPosition = initialPosition
      move.toValue = endPosition
    } else {
      endPosition = CGPoint(x: initialPosition.x + offsetX,
                            y: initialPosition.y + offsetY)
      move.fromValue = initialPosition
      move.toValue = endPosition
    }

    animationGroup.animations = [fade, move]
    
    // Update the actual properties to match final state
    placeholder.alphaValue = show ? 1 : 0
    placeholder.layer?.position = endPosition ?? .zero
    
    placeholder.layer?.add(animationGroup, forKey: nil)
  }
  
  func getTypingLineHeight() -> CGFloat {
    let lineHeightMultiple = paragraphStyle.lineHeightMultiple.isAlmostZero() ? 1.0 : paragraphStyle.lineHeightMultiple
    return calculateDefaultLineHeight(for: font) * lineHeightMultiple
  }
  
  func focus() {
    window?.makeFirstResponder(textView)
  }
  
  func clear() {
    textView.string = ""
    showPlaceholder(true)
  }
  
  func resetTextViewInsets() {
    let lineHeight = getTypingLineHeight()
    textView.textContainerInset = NSSize(
      width: 0,
      height: (minHeight - lineHeight) / 2
    )
  }
  
  func updateTextViewInsets(contentHeight: CGFloat) {
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
      guard let self = self else { return }
      let currentRange = self.textView.selectedRange
      self.textView.selectedRange = NSMakeRange(currentRange.location, 0)
      self.textView.setNeedsDisplay(textView.bounds)
    }
  }
}
