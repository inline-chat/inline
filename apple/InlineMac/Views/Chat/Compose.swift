import AppKit
import Combine
import InlineKit
import SwiftUI

struct Compose: View {
  var chatId: Int64?
  var peerId: Peer
  // Used for optimistic UI
  var topMsgId: Int64?
  
  @EnvironmentObject var data: DataManager
  @Environment(\.appDatabase) var db
  @Environment(\.colorScheme) var colorScheme
  
  @State private var text: String = ""
  @State private var event: ComposeTextEditorEvent = .none
  @State private var editorHeight: CGFloat = 42
  
  var minHeight: CGFloat = 42
  var textViewHorizontalPadding: CGFloat = Theme.messageHorizontalStackSpacing

  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      attachmentButton
        .frame(height: minHeight, alignment: .center)

      CustomTextEditor(
        text: $text,
        event: $event,
        minHeight: minHeight,
        height: $editorHeight,
        
        horizontalPadding: textViewHorizontalPadding,
        verticalPadding: 4,
        font: Theme.messageTextFont
      )
      .frame(height: editorHeight)
      .disableAnimations()
      .onChange(of: event) { newEvent in
        if newEvent == .none { return }
        handleEditorEvent(newEvent)
        event = .none
      }
      .onChange(of: text) { newText in
        // Send compose action for typing
        if newText.isEmpty {
          Task { await ComposeActions.shared.stoppedTyping(for: peerId) }
        } else {
          Task { await ComposeActions.shared.startedTyping(for: peerId) }
        }
      }
        
      .background(alignment: .leading) {
        if text.isEmpty {
          Text("Write a message")
            .foregroundStyle(.tertiary)
            .padding(.leading, textViewHorizontalPadding)
            .allowsHitTesting(false)
            .frame(height: editorHeight)
            .transition(
              .asymmetric(
                insertion: .offset(x: 60),
                removal: .offset(x: 60)
              )
              .combined(with: .opacity)
            )
        }
      }
      .animation(.smoothSnappy.speed(1.5), value: text.isEmpty)
     
      sendButton
        .frame(height: minHeight, alignment: .center)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
    // Matches the chat view background
    .animation(.easeOut.speed(4), value: canSend)
    .padding(.horizontal, Theme.messageSidePadding)
    .background(Color(.textBackgroundColor))
    .overlay(alignment: .top) {
      Divider()
        .frame(height: 1)
        .offset(y: -1)
    }
  }
  
  @State var attachmentOverlayOpen = false
  
  @ViewBuilder
  var attachmentButton: some View {
    Button {
      // open picker
      withAnimation(.smoothSnappy) {
        attachmentOverlayOpen.toggle()
      }
    } label: {
      Image(systemName: "plus")
        .resizable()
        .scaledToFit()
        .foregroundStyle(.tertiary)
        .fontWeight(.bold)
    }
    .buttonStyle(
      CircleButtonStyle(
        size: Theme.messageAvatarSize,
        backgroundColor: .clear,
        hoveredBackgroundColor: .gray.opacity(0.1)
      )
    )
    .background(alignment: .bottomLeading) {
      if attachmentOverlayOpen {
        VStack {
          Text("Soon you can attach photos and files from here!").padding()
        }.frame(width: 140, height: 140)
          .background(.regularMaterial)
          .zIndex(2)
          .cornerRadius(12)
          .offset(x: 10, y: -50)
          .transition(.scale(scale: 0, anchor: .bottomLeading).combined(with: .opacity))
      }
    }
  }
  
  var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  @ViewBuilder
  var sendButton: some View {
    if canSend {
      Button {
        send()
      } label: {
//        Image(systemName: "paperplane.fill")
//        Image(systemName: "arrowtriangle.up.fill")
        Image(systemName: "arrow.up")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.white)
          .fontWeight(.bold)
      }
      .buttonStyle(
        CircleButtonStyle(
          size: Theme.messageAvatarSize,
          backgroundColor: .accentColor,
          hoveredBackgroundColor: .accentColor.opacity(0.8)
        )
      )
    }
  }
  
  private func handleEditorEvent(_ event: ComposeTextEditorEvent) {
    switch event {
    case .focus:
      break
      
    case .blur:
      break
      
    case .send:
      send()
      
    case .insertNewline:
      // Do nothing - let the text view handle the newline
      break
      
    case .dismiss:
      break
      
    default:
      break
    }
  }
  
  struct CircleButtonStyle: ButtonStyle {
    let size: CGFloat
    let backgroundColor: Color
    let hoveredBackground: Color
    
    @State private var isHovering = false
    
    init(
      size: CGFloat = 32,
      backgroundColor: Color = .blue,
      hoveredBackgroundColor: Color = .blue.opacity(0.8)
    ) {
      self.size = size
      self.backgroundColor = backgroundColor
      self.hoveredBackground = hoveredBackgroundColor
    }
    
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .padding(8)
        .frame(width: size, height: size)
        .background(
          Circle()
            .fill(isHovering ? hoveredBackground : backgroundColor)
        )
        .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
        .onHover { hovering in
          withAnimation(.easeInOut(duration: 0.2)) {
            isHovering = hovering
          }
        }
    }
  }
 
  private func send() {
    Task {
      let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      do {
        guard !messageText.isEmpty else { return }
        guard let chatId = chatId else {
          Log.shared.warning("Chat ID is nil, cannot send message")
          return
        }
        
        text = ""
        
        // Reset editor height after clearing text
        editorHeight = minHeight
        
        let peerUserId: Int64? = if case .user(let id) = peerId { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peerId { id } else { nil }
        
        let randomId = Int64.random(in: Int64.min ... Int64.max)
        let message = Message(
          messageId: -randomId,
          randomId: randomId,
          fromId: Auth.shared.getCurrentUserId()!,
          date: Date(),
          text: messageText,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          chatId: chatId
        )
        
        try await db.dbWriter.write { db in
          try message.save(db)
        }
        
        // TODO: Scroll to bottom
        
        try await data.sendMessage(
          chatId: chatId,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          text: messageText,
          peerId: peerId,
          randomId: randomId,
          repliedToMessageId: nil
        )
        
      } catch {
        Log.shared.error("Failed to send message", error: error)
        // Optionally show error to user
      }
    }
  }
}

enum ComposeTextEditorEvent {
  case none
  case focus
  case blur
  case send
  case insertNewline
  case dismiss
}

struct CustomTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var event: ComposeTextEditorEvent
  var minHeight: CGFloat
  @Binding var height: CGFloat
//  var onEvent: (ComposeTextEditorEvent) -> Void
//  @Binding var isFocused: Bool
  var horizontalPadding: CGFloat = 8
  var verticalPadding: CGFloat = 6
  var font: NSFont = .preferredFont(forTextStyle: .body)
  
//  init(
//    text: Binding<String>,
//    minHeight: CGFloat,
//    height: Binding<CGFloat>,
//    onEvent: @escaping (ComposeTextEditorEvent) -> Void,
  ////    isFocused: Binding<Bool>,
//    horizontalPadding: CGFloat = 8,
//    verticalPadding: CGFloat = 6,
//    font: NSFont = .preferredFont(forTextStyle: .body)
//  ) {
//    self._text = text
//    self.minHeight = minHeight
//    self._height = height
//    self.onEvent = onEvent
  ////    self._isFocused = isFocused
//    self.horizontalPadding = horizontalPadding
//    self.verticalPadding = verticalPadding
//    self.font = font
//  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  let paragraphStyle: NSParagraphStyle = {
    let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
    let lineSpacing: CGFloat = 0.0
    paragraph.lineSpacing = lineSpacing
    paragraph.baseWritingDirection = .natural
    return paragraph
  }()
  
  // line height based on current typing font and current typing paragraph
  var typingLineHeight: CGFloat {
    let lineHeightMultiple = paragraphStyle.lineHeightMultiple.isAlmostZero() ? 1.0 : paragraphStyle.lineHeightMultiple
    return calculateDefaultLineHeight(for: font) * lineHeightMultiple
  }
  
  func makeScrollView() -> ComposeScrollView {
    let scrollView = ComposeScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalRuler = false
    scrollView.autoresizingMask = [.width]
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.contentInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    scrollView.verticalScrollElasticity = .none
   
    return scrollView
  }
  
  func makeTextView() -> NSTextView {
    let textView = CustomTextView()
//    let textView = NSTextView()

    textView.drawsBackground = false
    textView.isRichText = false
    textView.font = font
    textView.textColor = NSColor.labelColor
    textView.allowsUndo = true
    textView.textColor = NSColor.labelColor
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isRichText = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.isHorizontallyResizable = false
    textView.isAutomaticLinkDetectionEnabled = true

    textView.typingAttributes = [
      .paragraphStyle: paragraphStyle,
      .font: font,
      .foregroundColor: NSColor.labelColor
    ]
    
    // Insets
    let lineHeight = typingLineHeight
    textView.textContainerInset = NSSize(
      width: 0,
      height: (minHeight - lineHeight) / 2
    )
    
    return textView
  }
  
  func onEvent(_ event: ComposeTextEditorEvent) {
    self.event = event
  }
  
  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = makeScrollView()
    let textView = makeTextView()
    
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = horizontalPadding
    
    // Hook it up
    textView.delegate = context.coordinator
    scrollView.documentView = textView

    // initial set
//      context.coordinator.updateHeightIfNeeded(for: textView)
    
    // Handle scroll view frame changes
    scrollView.onFrameChange = { [weak textView] _ in
      guard let textView else { return }
      context.coordinator.updateHeightIfNeeded(for: textView)
    }
    
    // Handle window size changes
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.windowDidResize(_:)),
      name: NSWindow.didResizeNotification,
      object: nil
    )
    
    DispatchQueue.main.async {
      focus(for: textView)
    }

    return scrollView
  }
  
  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    
    if textView.string != text {
      let selectedRanges = textView.selectedRanges
      textView.string = text
      textView.selectedRanges = selectedRanges
      context.coordinator.updateHeightIfNeeded(for: textView)
    }
    
    // Handle focus updates
//    handleFocusUpdate(for: textView)
  }
  
//  private func handleFocusUpdate(for textView: NSTextView) {
//    guard let window = textView.window else { return }
//
//    let shouldBeFocused = isFocused
//    let isFocused = window.firstResponder === textView
//
//    guard shouldBeFocused != isFocused else { return }
//
//    DispatchQueue.main.async {
//      window.makeFirstResponder(shouldBeFocused ? textView : nil)
//    }
//  }
  
  private func focus(for textView: NSTextView) {
    guard let window = textView.window else { return }
    // Focus the text view
    window.makeFirstResponder(textView)
  }
  
  private func calculateMaxHeight(for window: NSWindow?) -> CGFloat {
    guard let window else { return 300 } // Fallback value
    let windowHeight = window.frame.height
    let maxHeight = windowHeight * 0.6
    
    // Add safety bounds
    return min(max(maxHeight, 100), 500)
  }

  class Coordinator: NSObject, NSTextViewDelegate, CustomTextViewDelegate {
    var parent: CustomTextEditor
    var lastHeight: CGFloat = 0
    var currentMaxHeight: CGFloat = 300 // Default value
    
    // Use computed property to always get fresh reference
    var onEvent: (ComposeTextEditorEvent) -> Void {
      return parent.onEvent
    }
    
    init(_ parent: CustomTextEditor) {
      self.parent = parent
      super.init()
    }
    
    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
      if textView.string.isRTL {
        textView.baseWritingDirection = .rightToLeft
      } else {
        textView.baseWritingDirection = .leftToRight
      }
      updateHeightIfNeeded(for: textView)
    }
    
    @objc func windowDidResize(_ notification: Notification) {
      guard let window = notification.object as? NSWindow,
            let textView = window.firstResponder as? NSTextView,
            textView.delegate === self else { return }
      
      // Update max height based on new window size
      currentMaxHeight = parent.calculateMaxHeight(for: window)
      updateHeightIfNeeded(for: textView)
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
      
      // Update max height based on current window
      currentMaxHeight = parent.calculateMaxHeight(for: textView.window)
      
      layoutManager.ensureLayout(for: textContainer)
      let contentHeight = layoutManager.usedRect(for: textContainer).height
      
      var newHeight = contentHeight + (parent.verticalPadding * 2)
      newHeight = max(parent.minHeight, min(currentMaxHeight, newHeight))
      
      // Only update if significant change
//      if abs(newHeight - lastHeight) > 0.1 {
      lastHeight = newHeight
      
      DispatchQueue.main.async {
        self.parent.height = newHeight
      }
        
      textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.string.count), actualCharacterRange: nil)
      layoutManager.ensureLayout(for: textContainer)
      updateTextViewInsets(textView, contentHeight: contentHeight)
    }

    private func updateTextViewInsets(_ textView: NSTextView, contentHeight: CGFloat) {
      let lineHeight = parent.typingLineHeight
      let newInsets = NSSize(
        width: 0,
        height: contentHeight <= lineHeight ?
          (parent.minHeight - lineHeight) / 2 :
          parent.verticalPadding
      )
      
      textView.textContainerInset = newInsets
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      // guard let textView = notification.object as? NSTextView else { return }
      // Handle selection changes if needed
    }
    
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      Log.shared.debug("commandSelector \(commandSelector)")
      switch commandSelector {
      case #selector(NSResponder.noResponder(for:)):
        print("noResponder")
        return false
      case #selector(NSResponder.insertNewline(_:)):
        let hasShiftModifier = NSEvent.modifierFlags.contains(.shift)
        
        if hasShiftModifier {
          onEvent(.insertNewline)
          updateHeightIfNeeded(for: textView)
          return false
        } else {
          // Only send if there's actual content
          if !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onEvent(.send)
            return true
          }
          return false
        }
        
      case #selector(NSResponder.cancelOperation(_:)):
        onEvent(.dismiss)
        return true
        
      default:
        return false
      }
    }
    
    func textViewDidPressReturn(_ textView: NSTextView) -> Bool {
      return false
    }
    
    func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool {
      onEvent(.send)
      return true
    }

    func textViewDidBecomeFirstResponder(_ notification: Notification) {
      onEvent(.focus)
    }
    
    func textViewDidResignFirstResponder(_ notification: Notification) {
      onEvent(.blur)
    }
  }
}

class CustomTextView: NSTextView {
  override func keyDown(with event: NSEvent) {
    // Check if the pressed key is Return/Enter
    if event.keyCode == 36 { // 36 is the key code for Return/Enter
      // Check if Shift key is held down
      if event.modifierFlags.contains(.shift) {
        // Insert a line break
//        insertNewline(self)
//        return
      } else if event.modifierFlags.contains(.command) {
        if let delegate = delegate as? CustomTextViewDelegate {
          if delegate.textViewDidPressCommandReturn(self) {
            return
          }
        }
      } else {
        // Handle regular Enter key press (e.g., submit form)
        // You can customize this behavior
        if let delegate = delegate as? CustomTextViewDelegate {
          if delegate.textViewDidPressReturn(self) {
            return
          }
        }
      }
    }
    
    super.keyDown(with: event)
  }
}

final class ComposeScrollView: NSScrollView {
  var onFrameChange: ((NSRect) -> Void)?
  
  override var frame: NSRect {
    didSet {
      if frame.width != oldValue.width {
        onFrameChange?(frame)
      }
    }
  }
}

protocol CustomTextViewDelegate: NSTextViewDelegate {
  func textViewDidPressReturn(_ textView: NSTextView) -> Bool
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool
}

// Alternative method using NSString
extension String {
  var isRTL: Bool {
    guard let firstChar = first else { return false }
    let earlyRTL = firstChar.unicodeScalars.first?.properties.generalCategory == .otherLetter &&
      firstChar.unicodeScalars.first != nil &&
      firstChar.unicodeScalars.first!.value >= 0x0590 &&
      firstChar.unicodeScalars.first!.value <= 0x08FF
    
    if earlyRTL { return true }

    let language = CFStringTokenizerCopyBestStringLanguage(self as CFString, CFRange(location: 0, length: count))
    if let language = language {
      return NSLocale.characterDirection(forLanguage: language as String) == .rightToLeft
    }
    return false
  }
}
