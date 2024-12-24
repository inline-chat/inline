import AppKit
import InlineKit
import SwiftUI

class ComposeAppKit: NSView {
  private var peerId: Peer
  private var chatId: Int64?
  private var viewModel: FullChatViewModel?
  private var heightConstraint: NSLayoutConstraint!
  private var minHeight = Theme.composeMinHeight
  private var verticalPadding = Theme.composeVerticalPadding
  // ---
  private var prevTextHeight: CGFloat = 0.0

  func update(viewModel: FullChatViewModel) {
    self.viewModel = viewModel
  }
  
  // MARK: Views
  
  private lazy var textEditor: ComposeTextEditor = {
    let textEditor = ComposeTextEditor()
    textEditor.translatesAutoresizingMaskIntoConstraints = false
    return textEditor
  }()
  
  // MARK: Initialization
    
  init(peerId: Peer) {
    self.peerId = peerId
    
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
    
  func setupView() {
//    backgroundColor = .textBackgroundColor
//    backgroundColor = NSColor.controlBackgroundColor
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    addSubview(border)
    addSubview(textEditor)
    
    setUpConstraints()
    setupTextEditor()
  }
  
  private func setUpConstraints() {
    heightConstraint = heightAnchor.constraint(equalToConstant: Theme.composeMinHeight)
    
    NSLayoutConstraint.activate([
      textEditor.leadingAnchor.constraint(equalTo: leadingAnchor),
      textEditor.trailingAnchor.constraint(equalTo: trailingAnchor),
      textEditor.topAnchor.constraint(equalTo: topAnchor),
      textEditor.bottomAnchor.constraint(equalTo: bottomAnchor),
      
//      heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.composeMinHeight)
      heightConstraint,
      
      // border
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.trailingAnchor.constraint(equalTo: trailingAnchor),
      border.topAnchor.constraint(equalTo: topAnchor),
      border.heightAnchor.constraint(equalToConstant: 1)
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
}
  
// MARK: Delegate
  
extension ComposeAppKit: NSTextViewDelegate, ComposeTextViewDelegate {
  // Implement delegate methods as needed
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool {
    return false
  }
  
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool {
    return false
  }
  
  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    
    // TODO: This is slow
    if textView.string.isRTL {
      textView.baseWritingDirection = .rightToLeft
    } else {
      textView.baseWritingDirection = .leftToRight
    }
    
    updateHeightIfNeeded(for: textView)
    
    if textView.string.isEmpty {
      // Handle empty text
      textEditor.showPlaceholder(true)
    } else {
      // Handle non-empty text
      textEditor.showPlaceholder(false)
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
    
    if abs(prevTextHeight - contentHeight) < 8.0 {
      // minimal change to height ignore
      return
    }
      
    prevTextHeight = contentHeight
    let maxHeight = 300.0
    let newHeight = ceil(contentHeight) + (Theme.composeVerticalPadding * 2)
    let height = max(Theme.composeMinHeight, min(maxHeight, newHeight))
    
    // First update the height of scroll view immediately so it doesn't clip from top while animating
    CATransaction.begin()
    CATransaction.disableActions()
    textEditor.setHeight(height)
    CATransaction.commit()
    
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.22
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      heightConstraint.animator().constant = height
      updateTextViewInsets(textView, contentHeight: contentHeight)
    }
  }
    
  private func updateTextViewInsets(_ textView: NSTextView, contentHeight: CGFloat) {
    let lineHeight = textEditor.getTypingLineHeight()
    let newInsets = NSSize(
      width: 0,
      height: contentHeight <= lineHeight ?
        (minHeight - lineHeight) / 2 :
        verticalPadding
    )

    textView.textContainerInset = newInsets
  }

//
  func textViewDidChangeSelection(_ notification: Notification) {
    // guard let textView = notification.object as? NSTextView else { return }
    // Handle selection changes if needed
  }
}
