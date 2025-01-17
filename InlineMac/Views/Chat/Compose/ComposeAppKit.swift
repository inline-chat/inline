import AppKit
import InlineKit
import SwiftUI

class ComposeAppKit: NSView {
  // Props
  private var peerId: Peer
  private var chatId: Int64? { viewModel?.chat?.id }
  
  // State
  private weak var messageList: MessageListAppKit?
  private var viewModel: FullChatViewModel?
  private var images: Set<NSImage> = []
  
  // Internal
  private var heightConstraint: NSLayoutConstraint!
  private var minHeight = Theme.composeMinHeight
  private var verticalPadding = 0.0
  // ---
  private var textViewContentHeight: CGFloat = 0.0
  private var textViewHeight: CGFloat = 0.0
  
  // Features
  private var feature_animateHeightChanges = false // for now until fixing how to update list view smoothly
  
  func update(viewModel: FullChatViewModel) {
    self.viewModel = viewModel
  }
  
  // MARK: Views
  
  private lazy var textEditor: ComposeTextEditor = {
    let textEditor = ComposeTextEditor()
    textEditor.translatesAutoresizingMaskIntoConstraints = false
    return textEditor
  }()
  
  private lazy var sendButton: ComposeSendButton = {
    let view = ComposeSendButton(frame: .zero, onSend: { [weak self] in
      self?.send()
    })
    return view
  }()
  
  private lazy var menuButton: ComposeMenuButton = {
    let view = ComposeMenuButton(frame: .zero)
    return view
  }()
  
  // Add attachments view
  private lazy var attachments: ComposeAttachments = {
    let view = ComposeAttachments(frame: .zero, compose: self)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
  
  // -------
  
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    
    // Focus the text editor
    focus()
  }
  
  // MARK: Initialization
    
  init(peerId: Peer, messageList: MessageListAppKit) {
    self.peerId = peerId
    self.messageList = messageList
    
    super.init(frame: .zero)
    setupView()
  }
    
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
    
  // MARK: Setup
  
  lazy var border = {
    let border = NSBox()
    border.boxType = .separator
    border.translatesAutoresizingMaskIntoConstraints = false
    return border
  }()
  
  lazy var background = {
    // Add vibrancy effect
    let material = NSVisualEffectView(frame: bounds)
    material.material = .headerView // Similar to toolbar
    material.blendingMode = .withinWindow
    material.state = .active
    material.translatesAutoresizingMaskIntoConstraints = false
    return material
  }()
    
  func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    // More distinct background
    layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
    
    addSubview(background)
    addSubview(border)
    addSubview(sendButton)
    addSubview(menuButton)
    addSubview(textEditor)
    addSubview(attachments)

    setUpConstraints()
    setupTextEditor()
  }
  
  private func setUpConstraints() {
    heightConstraint = heightAnchor.constraint(equalToConstant: Theme.composeMinHeight)
    
    NSLayoutConstraint.activate([
      heightConstraint,
      
      // bg
      background.leadingAnchor.constraint(equalTo: leadingAnchor),
      background.trailingAnchor.constraint(equalTo: trailingAnchor),
      background.topAnchor.constraint(equalTo: topAnchor),
      background.bottomAnchor.constraint(equalTo: bottomAnchor),
      
      // send
      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            
      // menu
      menuButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      menuButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      
      // Add attachments constraints
      attachments.leadingAnchor.constraint(equalTo: textEditor.leadingAnchor),
      attachments.trailingAnchor.constraint(equalTo: textEditor.trailingAnchor),
      attachments.topAnchor.constraint(equalTo: topAnchor),
      
      // text editor
      textEditor.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor),
      textEditor.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor),
      textEditor.bottomAnchor.constraint(equalTo: bottomAnchor),
      
      // Update text editor top constraint
      // textEditor.topAnchor.constraint(equalTo: topAnchor),
      textEditor.topAnchor.constraint(equalTo: attachments.bottomAnchor),
      
      // top seperator border
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.trailingAnchor.constraint(equalTo: trailingAnchor),
      border.topAnchor.constraint(equalTo: topAnchor),
      border.heightAnchor.constraint(equalToConstant: 1),
    ])
  }
  
  private func setupTextEditor() {
    // Set the delegate if needed
    textEditor.delegate = self
  }
    
  // MARK: - Public Interface
    
  var text: String {
    get { textEditor.string }
    set { textEditor.string = newValue }
  }
    
  func focusEditor() {
    textEditor.focus()
  }
  
  // MARK: - Height
  
  private func getTextViewHeight() -> CGFloat {
    // FIXME: move to text editor
    textViewHeight = max(textEditor.minHeight, textViewContentHeight + textEditor.verticalPadding * 2)
    return textViewHeight
  }

  // Get compose height
  private func getHeight() -> CGFloat {
    let textViewHeight = getTextViewHeight()
    let contentHeight = max(textEditor.minHeight, textViewHeight) // FIXME:
    let attachmentsHeight = attachments.getHeight()
    let height = contentHeight + attachmentsHeight + verticalPadding
    let maxHeight = 300.0
    let capped = max(Theme.composeMinHeight, min(maxHeight, height))
    return capped
  }
  
  func updateHeight() {
    let height = getHeight()
    let textViewHeight = getTextViewHeight()

    if feature_animateHeightChanges {
      // First update the height of scroll view immediately so it doesn't clip from top while animating
      CATransaction.begin()
      CATransaction.disableActions()
      textEditor.setHeight(height)
      CATransaction.commit()
      
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        // Disable screen updates during animation setup
        NSAnimationContext.beginGrouping()
        heightConstraint.animator().constant = height
        textEditor.updateTextViewInsets(contentHeight: textViewContentHeight) // use height without paddings
        messageList?.updateInsetForCompose(height)
        NSAnimationContext.endGrouping()
      }
    } else {
      textEditor.setHeight(height)
      heightConstraint.constant = height
      textEditor.updateTextViewInsets(contentHeight: textViewContentHeight)
      messageList?.updateInsetForCompose(height)
    }
  }
  
  private var ignoreNextHeightChange = false
  
  // MARK: - Actions
  
  func addImage(_ image: NSImage) {
    images.insert(image)
    attachments.addImageView(image)
    updateHeight()
  }
  
  func removeImage(_ image: NSImage) {
    images.remove(image)
    attachments.removeImageView(image)
    updateHeight()
  }
  
  func clearAttachments(updateHeights: Bool = false) {
    images.removeAll()
    attachments.clearViews()
    if updateHeights {
      updateHeight()
    }
  }
  
  // Clear, reset height
  func clear() {
    // State
    images.removeAll()
    sendButton.updateCanSend(false)
    
    // Views
    attachments.clearViews()
    textViewContentHeight = textEditor.getTypingLineHeight() // manually for now, FIXME: make it automatic in texteditor.clear
    textEditor.clear()
    clearAttachments(updateHeights: false)
    
    // must be last call
    updateHeight()
  }
  
  // Send the message
  func send() {
    DispatchQueue.main.async {
      self.ignoreNextHeightChange = true
      let rawText = self.textEditor.string
      let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      let canSend = !text.isEmpty
      let images = self.images
      
      if !canSend { return }
    
      // Clear immediately
      self.clear()
      
      // Add message
  
      let _ = Transactions.shared.mutate(
        transaction:
        .sendMessage(
          .init(text: text, peerId: self.peerId, chatId: self.chatId ?? 0) // FIXME: chatId
        )
      )
      
      self.ignoreNextHeightChange = false
    }
  }
  
  func focus() {
    textEditor.focus()
  }
}
  
// MARK: Delegate
  
extension ComposeAppKit: NSTextViewDelegate, ComposeTextViewDelegate {
  // Implement delegate methods as needed
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool {
    return false
  }
  
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool {
    // Send
    send()
    return true // handled
  }
  
  func textView(_ textView: NSTextView, didReceiveImage image: NSImage) {
    print("Image received for upload: \(image.size)")
    
    addImage(image)
  }
  
  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    
    // TODO: This is slow
    if textView.string.isRTL {
      textView.baseWritingDirection = .rightToLeft
    } else {
      textView.baseWritingDirection = .leftToRight
    }
    
    if !ignoreNextHeightChange {
      updateHeightIfNeeded(for: textView)
    }

    if textView.string.isEmpty {
      // Handle empty text
      textEditor.showPlaceholder(true)
      sendButton.updateCanSend(false)
      
      // Cancel typing
      Task {
        await ComposeActions.shared.stoppedTyping(for: self.peerId)
      }
    } else {
      // Handle non-empty text
      textEditor.showPlaceholder(false)
      sendButton.updateCanSend(true)
      
      // Start typing
      Task {
        await ComposeActions.shared.startedTyping(for: self.peerId)
      }
    }
  }
    
  func calculateContentHeight(for textView: NSTextView) -> CGFloat {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer else { return 0 }
    
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height
  }
  
  func updateHeightIfNeeded(for textView: NSTextView) {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer else { return }

    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height
    
    if abs(textViewContentHeight - contentHeight) < 8.0 {
      // minimal change to height ignore
      return
    }
    
    textViewContentHeight = contentHeight
   
    updateHeight()
  }
    
//
  func textViewDidChangeSelection(_ notification: Notification) {
    // guard let textView = notification.object as? NSTextView else { return }
    // Handle selection changes if needed
  }
}
