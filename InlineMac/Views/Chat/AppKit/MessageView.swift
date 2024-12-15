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
    if let width = props.width, let height = props.height {
//      let textViewWidth = MessageSizeCalculator.getTextViewWidth(for: width)
//      let size = NSSize(width: width, height: height)
//      textView.textContainer?.size = size
//      textView.setFrameSize(size) // This is the key addition
    }
    
    // -------------
    // AUTO SIZE
//    textView.isVerticallyResizable = true
//    textView.isHorizontallyResizable = false
    ////    let maxWidth = self.bounds.width
//    let maxWidth = 351.0
//    textView.textContainer?.widthTracksTextView = true
//    textView.textContainer?.heightTracksTextView = false
//    textView.textContainer?.size.width = maxWidth // <----
//    textView.maxSize = NSSize(width: maxWidth, height: 10000) // <----
//
//    //    textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
//    //    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
//    //     textView.alignment = .natural
    
    return textView
  }()

//  private lazy var contentStackView: NSStackView = {
//    let stack = NSStackView()
//    stack.translatesAutoresizingMaskIntoConstraints = false
//    stack.orientation = .vertical
//    stack.spacing = Theme.messageVerticalStackSpacing
//    stack.alignment = .leading
//    stack.edgeInsets = NSEdgeInsets(
//      top: 0,
//      left: 0,
//      bottom: 0,
//      right: 0
//    )
//    return stack
//  }()

//  private lazy var horizontalStackView: NSStackView = {
//    let stack = NSStackView()
//    stack.translatesAutoresizingMaskIntoConstraints = false
//    stack.orientation = .horizontal
//    stack.spacing = Theme.messageHorizontalStackSpacing
//    stack.edgeInsets = NSEdgeInsets(
//      top: 0,
//      left: Theme.messageSidePadding,
//      bottom: 0,
//      right: Theme.messageSidePadding
//    )
//
//    stack.alignment = .top
//    return stack
//  }()
//

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

  private func setupView() {
//    wantsLayer = true

    if showsName {
      addSubview(nameLabel)
      nameLabel.stringValue = from.firstName ?? from.username ?? ""
    }
    
    addSubview(messageTextView)
    setupMessageText()
    setupConstraints()
    setupContextMenu()
  }
  
  private var textViewWidthConstraint: NSLayoutConstraint!
  
  private func setupConstraints() {
    let avatarLeading = Theme.messageSidePadding
    let contentLeading = avatarLeading + Self.avatarSize + Theme.messageHorizontalStackSpacing
    
    let topPadding = props.isFirstMessage ? Theme.messageListTopInset + Theme.messageVerticalPadding : Theme.messageVerticalPadding
    let bottomPadding = props.isLastMessage ? Theme.messageListBottomInset + Theme.messageVerticalPadding : Theme.messageVerticalPadding
    
    if showsName {
      NSLayoutConstraint.activate([
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading),
        nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
        nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.messageSidePadding)
      ])
      
      nameLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)
      nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    
    textViewWidthConstraint = messageTextView.widthAnchor.constraint(equalToConstant: props.width ?? 0.0)
    
    // Message text view constraints
    NSLayoutConstraint.activate(
      [
        messageTextView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading),
        messageTextView.topAnchor.constraint(
          equalTo: showsName ? nameLabel.bottomAnchor : topAnchor,
          constant: showsName ? Theme.messageVerticalStackSpacing : topPadding
        ),
        messageTextView.bottomAnchor
          .constraint(
            equalTo: bottomAnchor,
            constant: -bottomPadding
          ),
        
        // This is accurate but requires careful updates
        textViewWidthConstraint
        
        // TODO: this results in automatic updated width on resize, but makes the text go up to the end of viewport which is undesirable.
//        messageTextView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.messageSidePadding)
      ]
    )
  }
  
  // Called when width/height changes
  public func updateSizes(props: MessageViewProps) {
    self.props = props
    textViewWidthConstraint.constant = props.width ?? 0.0
  }
  
  // Experimental: Called when only the text changes
  public func updateInnerContent(fullMessage: FullMessage, props: MessageViewProps) {
    self.fullMessage = fullMessage
    self.props = props
    
    nameLabel.stringValue = from.firstName ?? from.username ?? ""
    setupMessageText()
    updateSizes(props: props)
    // WIP..
  }

  private func setupMessageText() {
    let text = message.text ?? ""
    
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
    
//    messageTextView.delegate = self
//    layoutSubtreeIfNeeded()
  }

  private func setupContextMenu() {
    let menu = NSMenu()
    
    let idItem = NSMenuItem(title: "ID: \(message.id)", action: nil, keyEquivalent: "")
    idItem.isEnabled = false
    menu.addItem(idItem)
    
    let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMessage), keyEquivalent: "c")
    menu.addItem(copyItem)
    
//    menu.delegate = self
    self.menu = menu
  }
  
  // MARK: - Actions

  @objc private func copyMessage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.text ?? "", forType: .string)
  }
}

// Custom NSTextView subclass to handle hit testing
class CustomTextView2: NSTextView {
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
