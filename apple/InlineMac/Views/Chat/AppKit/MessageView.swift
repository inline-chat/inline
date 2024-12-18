// MessageView.swift
import AppKit
import InlineKit
import InlineUI
import SwiftUI

struct MessageViewProps: Equatable, Codable, Hashable {
  /// Used to show sender and photo
  var firstInGroup: Bool
  var isLastMessage: Bool
  var isFirstMessage: Bool
  var width: CGFloat?
  var height: CGFloat?
  
//  private var rtl: Bool
  
  // Compare everything except size
  func equalContentTo(_ other: MessageViewProps) -> Bool {
    firstInGroup == other.firstInGroup &&
      isLastMessage == other.isLastMessage &&
      isFirstMessage == other.isFirstMessage
  }
  
  /// Used in cache key
  func toString() -> String {
    "\(firstInGroup ? "FG" : "")\(isLastMessage == true ? "LM" : "")\(isFirstMessage == true ? "FM" : "")"
  }
}

class CacheAttrs {
  let cache: NSCache<NSString, NSAttributedString>
  
  init() {
    cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 1000 // Set appropriate limit
  }
  
  func get(key: String) -> NSAttributedString? {
    cache.object(forKey: NSString(string: key))
  }
  
  func set(key: String, value: NSAttributedString) {
    cache.setObject(value, forKey: NSString(string: key))
  }
  
  func clear() {
    cache.removeAllObjects()
  }
}

class MessageViewAppKit: NSView {
  static let avatarSize: CGFloat = Theme.messageAvatarSize
  static let cacheAttrs = CacheAttrs()
  
  // MARK: - Properties

  private var fullMessage: FullMessage
  private var props: MessageViewProps
  private var from: User {
    fullMessage.user ?? User.deletedInstance
  }

  private var showsAvatar: Bool { props.firstInGroup }
  private var showsName: Bool { props.firstInGroup }
  private var message: Message {
    fullMessage.message
  }

  // MARK: - UI Components

  private lazy var contentView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = 8
    return view
  }()
  
  private lazy var textStackView: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    return stack
  }()
  
  private lazy var nameLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = Theme.messageSenderFont
    label.lineBreakMode = .byTruncatingTail
    
    return label
  }()
  
  private lazy var messageTextView: NSTextView = {
    let textView = CustomTextView2()
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    
    // For international langs to not be clipped
    textView.clipsToBounds = false
    
    // for Debug
//    textView.backgroundColor = .blue.withAlphaComponent(0.1)
//    textView.drawsBackground = true
//    textView.textContainer?.lineFragmentPadding = 0
//    textView.textContainerInset = .zero
    
    // Match calculator configuration exactly
    textView.textContainer?.lineFragmentPadding = MessageTextConfiguration.lineFragmentPadding
    textView.textContainerInset = MessageTextConfiguration.containerInset
    textView.font = MessageTextConfiguration.font
    // Disable first mouse
    
    // -------------
    // SIZE FROM OUTSIDE
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = true

    // Disable smart insertions and replacements for better performance
    textView.smartInsertDeleteEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false

    // Don't know what this does
//    if let width = props.width, let height = props.height {
//      let size = NSSize(width: width, height: height)
//      textView.setFrameSize(size) // This probably helps...
//    }
 
    textView.delegate = self

    return textView
  }()

  // MARK: - Initialization

  init(fullMessage: FullMessage, props: MessageViewProps) {
    self.fullMessage = fullMessage
    self.props = props
    super.init(frame: .zero)
    setupView()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private var rtl = false
  
  private func setupView() {
    addSubview(contentView)
    contentView.addSubview(textStackView)
    
    if showsName {
      contentView.addSubview(nameLabel)
      nameLabel.stringValue = from.firstName ?? from.username ?? ""
      nameLabel.textColor = NSColor(
        InitialsCircle.ColorPalette
          .color(for: nameLabel.stringValue)
//          .adjustLuminosity(by: -0.1) // TODO: Optimize
      )
    }
    
//    contentView.addSubview(messageTextView)
    textStackView.addArrangedSubview(messageTextView)
    
    setupMessageText() // must be before constraints so RTL is set
    
    textStackView.alignment = rtl ? .right : .left
    
    setupConstraints()
    setupContextMenu()
  }
  
  private var textViewWidthConstraint: NSLayoutConstraint!
  private var textViewHeightConstraint: NSLayoutConstraint!
  private var textViewLeadingConstraint: NSLayoutConstraint!
  private var textViewTrailingConstraint: NSLayoutConstraint!
  
  private func setupConstraints() {
    
    var topSpacing = props.isFirstMessage ? Theme.messageListTopInset : 0.0
    let topPadding = Theme.messageVerticalPadding
    let bottomPadding = Theme.messageVerticalPadding
    let bottomSpacing = props.isLastMessage ? Theme.messageListBottomInset : 0.0
    let bgPadding = 6.0
    let avatarLeading = Theme.messageSidePadding 
    let contentLeading = avatarLeading + Self.avatarSize + Theme.messageHorizontalStackSpacing - bgPadding
    let sidePadding = Theme.messageSidePadding - bgPadding
    
    if props.firstInGroup {
      topSpacing += Theme.messageGroupSpacing
    }
    
    NSLayoutConstraint.activate([
      contentView.topAnchor.constraint(equalTo: topAnchor, constant: topSpacing),
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: bgPadding),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -bgPadding),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomSpacing)
    ])
    
    if showsName {
      NSLayoutConstraint.activate([
        nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: contentLeading),
        nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: topPadding),
        nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -sidePadding)
      ])
      
      nameLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)
      nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    textViewWidthConstraint = messageTextView.widthAnchor.constraint(equalToConstant: props.width ?? 0.0)
    textViewHeightConstraint = messageTextView.heightAnchor
      .constraint(
        equalToConstant: MessageSizeCalculator
          .getTextViewHeight(for: props)
      )
    
    NSLayoutConstraint.activate(
      [
        textStackView.topAnchor.constraint(
          equalTo: showsName ? nameLabel.bottomAnchor : contentView.topAnchor,
          constant: showsName ? Theme.messageVerticalStackSpacing : topPadding
        ),
        textStackView.bottomAnchor
          .constraint(
            equalTo: contentView.bottomAnchor,
            constant: -bottomPadding
          ),
        textStackView.leadingAnchor.constraint(
          equalTo: contentView.leadingAnchor,
          constant: contentLeading
        ),
        textStackView.trailingAnchor.constraint(
          equalTo: contentView.trailingAnchor,
          constant: -sidePadding
        )
      ]
    )
    
    // Message text view constraints
    NSLayoutConstraint.activate(
      [
        // This is accurate but requires careful updates
        textViewWidthConstraint,
        textViewHeightConstraint
      ]
    )
  }
  
  // Called when width/height changes
  public func updateSizes(props: MessageViewProps) {
    self.props = props
    textViewWidthConstraint.constant = props.width ?? 0.0
    textViewHeightConstraint.constant = MessageSizeCalculator
      .getTextViewHeight(for: props)
  }
  
  // Experimental: Called when only the text changes
  public func updateInnerContent(fullMessage: FullMessage, props: MessageViewProps) {
    self.fullMessage = fullMessage
    self.props = props
    
    nameLabel.stringValue = from.firstName ?? from.username ?? ""
    setupMessageText()
    updateSizes(props: props)
    
    // update rtl
    textStackView.alignment = rtl ? .trailing : .leading
//    textViewTrailingConstraint.isActive = rtl
//    textViewLeadingConstraint.isActive = !rtl
    // WIP..
  }
  
  private func setupMessageText() {
    let text = message.text ?? ""
    
    if text.isRTL {
      rtl = true
      messageTextView.baseWritingDirection = .rightToLeft
    } else {
      rtl = false
      messageTextView.baseWritingDirection = .natural
    }

    let key = "\(text)"
    if let attrs = Self.cacheAttrs.get(key: key) {
      messageTextView.textStorage?.setAttributedString(attrs)
      return
    }
    
    // Create mutable attributed string
    let attributedString = NSMutableAttributedString(
      // Trim to avoid known issue with size calculator
      string: text.trimmingCharacters(in: .whitespacesAndNewlines),
      attributes: [
        .font: MessageTextConfiguration.font,
        .foregroundColor: NSColor.labelColor
      ]
    )
    
    // Detect and add links
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    if let detector = detector {
      let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
      
      for match in matches {
        if let url = match.url {
          attributedString.addAttributes([
            .cursor: NSCursor.pointingHand,
            .link: url,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
          ], range: match.range)
        }
      }
    }
    
    messageTextView.textStorage?.setAttributedString(attributedString)
    Self.cacheAttrs.set(key: key, value: attributedString)
    
//    layoutSubtreeIfNeeded()
  }

  private func setupContextMenu() {
    let menu = NSMenu()
    
    let idItem = NSMenuItem(title: "ID: \(message.id)", action: nil, keyEquivalent: "")
    idItem.isEnabled = false
    menu.addItem(idItem)
    
    let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMessage), keyEquivalent: "c")
    menu.addItem(copyItem)
    
    menu.delegate = self
    self.menu = menu
  }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    // Apply selection style when menu is about to open
    contentView.layer?.backgroundColor = NSColor.darkGray
      .withAlphaComponent(0.1).cgColor
  }
  
  override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
    // Remove selection style when menu closes
    contentView.layer?.backgroundColor = nil
  }

  // MARK: - Actions

  @objc private func copyMessage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.text ?? "", forType: .string)
  }
  
  // MARK: Hover

  private func updateHoverState() {
    guard window?.isKeyWindow == true else {
      layer?.backgroundColor = nil
      return
    }
    
    // Disable implicit animations during scrolling
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.08
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      context.allowsImplicitAnimation = true
      
      if isHovered {
        contentView.layer?.backgroundColor = NSColor.darkGray
          .withAlphaComponent(0.04).cgColor
      } else {
        contentView.layer?.backgroundColor = nil
      }
    }
  }

  override func viewDidHide() {
    super.viewDidHide()
    clearHoverState()
  }
  
  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateTrackingAreas()
  }
  
  private var isHovered = false {
    didSet {
      if isHovered != oldValue {
        updateHoverState()
      }
    }
  }

  private var trackingArea: NSTrackingArea?
  
  private func clearHoverState() {
    isHovered = false
    layer?.backgroundColor = nil
  }
  
  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
  }
  
  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    
    if let trackingArea = trackingArea {
      removeTrackingArea(trackingArea)
    }
    
    let options: NSTrackingArea.Options = [
      .mouseEnteredAndExited,
      .activeAlways,
      .inVisibleRect // Add this option
    ]
    
    trackingArea = NSTrackingArea(
      rect: bounds,
      options: options,
      owner: self,
      userInfo: nil
    )
    
    if let trackingArea = trackingArea {
      addTrackingArea(trackingArea)
    }
    
    // Check if mouse is actually over the view
    if let window = window {
      let mousePoint = window.mouseLocationOutsideOfEventStream
      let localPoint = convert(mousePoint, from: nil)
      isHovered = bounds.contains(localPoint) && window.isKeyWindow
    }
  }
}

extension MessageViewAppKit: NSTextViewDelegate {
  // Custom menu for text
}
  
extension MessageViewAppKit: NSMenuDelegate {}

// Custom NSTextView subclass to handle hit testing
class CustomTextView2: NSTextView {
  override func resignFirstResponder() -> Bool {
    // Clear out selection when user clicks somewhere else
    selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
    
    return super.resignFirstResponder()
  }
  
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return false
  }
  
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Prevent hit testing when window is inactive
    guard let window = window, window.isKeyWindow else {
      return nil
    }
    return super.hitTest(point)
  }
  
  override func mouseDown(with event: NSEvent) {
    // Ensure window is key before handling mouse events
    guard let window = window else {
      super.mouseDown(with: event)
      return
    }
    
    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
      // Optionally, you can choose to not forward the event
      return
    }
    
    super.mouseDown(with: event)
  }
}
