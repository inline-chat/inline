// import AppKit
// import SwiftUI
// import InlineKit
//
// enum ComposeTextEditorEvent {
//  case none
//  case focus
//  case blur
//  case send
//  case insertNewline
//  case dismiss
// }
//
// struct CustomTextEditor: NSViewRepresentable {
//  @Binding var text: String
//  @Binding var event: ComposeTextEditorEvent
//  var minHeight: CGFloat
//  @Binding var height: CGFloat
//  //  var onEvent: (ComposeTextEditorEvent) -> Void
//  //  @Binding var isFocused: Bool
//  var horizontalPadding: CGFloat = 8
//  var verticalPadding: CGFloat = 6
//  var font: NSFont = .preferredFont(forTextStyle: .body)
//
//  func makeCoordinator() -> Coordinator {
//    Coordinator(self)
//  }
//
//  let paragraphStyle: NSParagraphStyle = {
//    let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
//    let lineSpacing: CGFloat = 0.0
//    paragraph.lineSpacing = lineSpacing
//    paragraph.baseWritingDirection = .natural
//    return paragraph
//  }()
//
//  // line height based on current typing font and current typing paragraph
//  var typingLineHeight: CGFloat {
//    let lineHeightMultiple = paragraphStyle.lineHeightMultiple.isAlmostZero() ? 1.0 :
//    paragraphStyle.lineHeightMultiple
//    return calculateDefaultLineHeight(for: font) * lineHeightMultiple
//  }
//
//  func makeScrollView() -> ComposeScrollView {
//    let scrollView = ComposeScrollView()
//    scrollView.drawsBackground = false
//    scrollView.hasVerticalScroller = false
//    scrollView.hasHorizontalRuler = false
//    scrollView.autoresizingMask = [.width]
//    scrollView.translatesAutoresizingMaskIntoConstraints = false
//    scrollView.contentInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
//    scrollView.verticalScrollElasticity = .none
//
//    return scrollView
//  }
//
//  func makeTextView() -> NSTextView {
//    let textView = CustomTextView()
//    //    let textView = NSTextView()
//
//    textView.drawsBackground = false
//    textView.isRichText = false
//    textView.font = font
//    textView.textColor = NSColor.labelColor
//    textView.allowsUndo = true
//    textView.textColor = NSColor.labelColor
//    textView.isAutomaticDashSubstitutionEnabled = false
//    textView.isRichText = false
//    textView.isVerticallyResizable = true
//    textView.autoresizingMask = [.width]
//    textView.isHorizontallyResizable = false
//    textView.isAutomaticLinkDetectionEnabled = true
//
//    textView.typingAttributes = [
//      .paragraphStyle: paragraphStyle,
//      .font: font,
//      .foregroundColor: NSColor.labelColor
//    ]
//
//    // Insets
//    let lineHeight = typingLineHeight
//    textView.textContainerInset = NSSize(
//      width: 0,
//      height: (minHeight - lineHeight) / 2
//    )
//
//    return textView
//  }
//
//  func onEvent(_ event: ComposeTextEditorEvent) {
//    self.event = event
//  }
//
//  func makeNSView(context: Context) -> NSScrollView {
//    let scrollView = makeScrollView()
//    let textView = makeTextView()
//
//    textView.textContainer?.widthTracksTextView = true
//    textView.textContainer?.lineFragmentPadding = horizontalPadding
//
//    // Hook it up
//    textView.delegate = context.coordinator
//    scrollView.documentView = textView
//
//    // initial set
//    //      context.coordinator.updateHeightIfNeeded(for: textView)
//
//    // Handle scroll view frame changes
//    scrollView.onFrameChange = { [weak textView] _ in
//      guard let textView else { return }
//      context.coordinator.updateHeightIfNeeded(for: textView)
//    }
//
//    // Handle window size changes
//    NotificationCenter.default.addObserver(
//      context.coordinator,
//      selector: #selector(Coordinator.windowDidResize(_:)),
//      name: NSWindow.didResizeNotification,
//      object: nil
//    )
//
//    DispatchQueue.main.async {
//      focus(for: textView)
//    }
//
//    return scrollView
//  }
//
//  func updateNSView(_ scrollView: NSScrollView, context: Context) {
//    guard let textView = scrollView.documentView as? NSTextView else { return }
//
//    if textView.string != text {
//      let selectedRanges = textView.selectedRanges
//      textView.string = text
//      textView.selectedRanges = selectedRanges
//      context.coordinator.updateHeightIfNeeded(for: textView)
//    }
//
//  }
//
//
//  private func focus(for textView: NSTextView) {
//    guard let window = textView.window else { return }
//    // Focus the text view
//    window.makeFirstResponder(textView)
//  }
//
//  private func calculateMaxHeight(for window: NSWindow?) -> CGFloat {
//    guard let window else { return 300 } // Fallback value
//    let windowHeight = window.frame.height
//    let maxHeight = windowHeight * 0.6
//
//    // Add safety bounds
//    return min(max(maxHeight, 100), 500)
//  }
//
//  class Coordinator: NSObject, NSTextViewDelegate, CustomTextViewDelegate {
//    var parent: CustomTextEditor
//    var lastHeight: CGFloat = 0
//    var currentMaxHeight: CGFloat = 300 // Default value
//
//    // Use computed property to always get fresh reference
//    var onEvent: (ComposeTextEditorEvent) -> Void {
//      return parent.onEvent
//    }
//
//    init(_ parent: CustomTextEditor) {
//      self.parent = parent
//      super.init()
//    }
//
//    func textDidChange(_ notification: Notification) {
//      guard let textView = notification.object as? NSTextView else { return }
//      parent.text = textView.string
//      if textView.string.isRTL {
//        textView.baseWritingDirection = .rightToLeft
//      } else {
//        textView.baseWritingDirection = .leftToRight
//      }
//      updateHeightIfNeeded(for: textView)
//    }
//
//    @objc func windowDidResize(_ notification: Notification) {
//      guard let window = notification.object as? NSWindow,
//            let textView = window.firstResponder as? NSTextView,
//            textView.delegate === self else { return }
//
//      // Update max height based on new window size
//      currentMaxHeight = parent.calculateMaxHeight(for: window)
//      updateHeightIfNeeded(for: textView)
//    }
//
//    func calculateContentHeight(for textView: NSTextView) -> CGFloat {
//      guard let layoutManager = textView.layoutManager,
//            let textContainer = textView.textContainer else { return 0 }
//
//      layoutManager.ensureLayout(for: textContainer)
//      return layoutManager.usedRect(for: textContainer).height
//    }
//
//    func updateHeightIfNeeded(for textView: NSTextView) {
//      guard let layoutManager = textView.layoutManager,
//            let textContainer = textView.textContainer else { return }
//
//      // Update max height based on current window
//      currentMaxHeight = parent.calculateMaxHeight(for: textView.window)
//
//      layoutManager.ensureLayout(for: textContainer)
//      let contentHeight = layoutManager.usedRect(for: textContainer).height
//
//      var newHeight = contentHeight + (parent.verticalPadding * 2)
//      newHeight = max(parent.minHeight, min(currentMaxHeight, newHeight))
//
//      // Only update if significant change
//      //      if abs(newHeight - lastHeight) > 0.1 {
//      lastHeight = newHeight
//
//
//      // Post notification with new height
//      NotificationCenter.default.post(
//        name: .composeViewHeightDidChange,
//        object: self,
//        userInfo: [ComposeHeightInfo.heightKey: newHeight]
//      )
//
//      DispatchQueue.main.async {
//        self.parent.height = newHeight
//      }
//
//      textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.string.count), actualCharacterRange: nil)
//      layoutManager.ensureLayout(for: textContainer)
//      updateTextViewInsets(textView, contentHeight: contentHeight)
//    }
//
//    private func updateTextViewInsets(_ textView: NSTextView, contentHeight: CGFloat) {
//      let lineHeight = parent.typingLineHeight
//      let newInsets = NSSize(
//        width: 0,
//        height: contentHeight <= lineHeight ?
//        (parent.minHeight - lineHeight) / 2 :
//          parent.verticalPadding
//      )
//
//      textView.textContainerInset = newInsets
//    }
//
//    func textViewDidChangeSelection(_ notification: Notification) {
//      // guard let textView = notification.object as? NSTextView else { return }
//      // Handle selection changes if needed
//    }
//
//    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
//      Log.shared.debug("commandSelector \(commandSelector)")
//      switch commandSelector {
//      case #selector(NSResponder.noResponder(for:)):
//        print("noResponder")
//        return false
//      case #selector(NSResponder.insertNewline(_:)):
//        let hasShiftModifier = NSEvent.modifierFlags.contains(.shift)
//
//        if hasShiftModifier {
//          onEvent(.insertNewline)
//          updateHeightIfNeeded(for: textView)
//          return false
//        } else {
//          // Only send if there's actual content
//          if !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//            onEvent(.send)
//            return true
//          }
//          return false
//        }
//
//      case #selector(NSResponder.cancelOperation(_:)):
//        onEvent(.dismiss)
//        return true
//
//      default:
//        return false
//      }
//    }
//
//    func textViewDidPressReturn(_ textView: NSTextView) -> Bool {
//      return false
//    }
//
//    func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool {
//      onEvent(.send)
//      return true
//    }
//
//    func textViewDidBecomeFirstResponder(_ notification: Notification) {
//      onEvent(.focus)
//    }
//
//    func textViewDidResignFirstResponder(_ notification: Notification) {
//      onEvent(.blur)
//    }
//  }
// }
//
// class CustomTextView: NSTextView {
//  override func keyDown(with event: NSEvent) {
//    // Check if the pressed key is Return/Enter
//    if event.keyCode == 36 { // 36 is the key code for Return/Enter
//      // Check if Shift key is held down
//      if event.modifierFlags.contains(.shift) {
//        // Insert a line break
//        //        insertNewline(self)
//        //        return
//      } else if event.modifierFlags.contains(.command) {
//        if let delegate = delegate as? CustomTextViewDelegate {
//          if delegate.textViewDidPressCommandReturn(self) {
//            return
//          }
//        }
//      } else {
//        // Handle regular Enter key press (e.g., submit form)
//        // You can customize this behavior
//        if let delegate = delegate as? CustomTextViewDelegate {
//          if delegate.textViewDidPressReturn(self) {
//            return
//          }
//        }
//      }
//    }
//
//    super.keyDown(with: event)
//  }
// }
//
// final class ComposeScrollView: NSScrollView {
//  var onFrameChange: ((NSRect) -> Void)?
//
//  override var frame: NSRect {
//    didSet {
//      if frame.width != oldValue.width {
//        onFrameChange?(frame)
//      }
//    }
//  }
// }
//
// protocol CustomTextViewDelegate: NSTextViewDelegate {
//  func textViewDidPressReturn(_ textView: NSTextView) -> Bool
//  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool
// }
