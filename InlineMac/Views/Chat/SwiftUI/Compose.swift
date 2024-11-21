import AppKit
import InlineKit
import SwiftUI

struct Compose: View {
  var chatId: Int64?
  var peerId: Peer
  // Used for optimistic UI
  var topMsgId: Int64?
  
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var scroller: ChatScroller
  @EnvironmentObject var focus: ChatFocus
  @Environment(\.appDatabase) var db
  @Environment(\.colorScheme) var colorScheme
  
  @State private var text: String = ""
  @State private var editorHeight: CGFloat = 42
  
  var minHeight: CGFloat = 42
  var horizontalPadding: CGFloat = 12
  
  var isFocused: Bool {
    focus.focusedField == .compose
  }
  
  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ZStack(alignment: .topLeading) {
        CustomTextEditor(
          text: $text,
          minHeight: minHeight,
          maxHeight: 160,
          height: $editorHeight,
          onEvent: handleEditorEvent,
          isFocused: Binding(
            get: { focus.focusedField == .compose },
            set: { newValue in
              focus.focusedField = newValue ? .compose : nil
            }
          ),
          horizontalPadding: horizontalPadding,
          verticalPadding: 4,
          font: .systemFont(ofSize: 13)
        )
        .frame(height: editorHeight)
        
        if text.isEmpty {
          Text("Write a message")
            .foregroundStyle(.tertiary)
            .padding(.leading, horizontalPadding)
            .allowsHitTesting(false)
            .frame(height: editorHeight)
            .transition(
              .asymmetric(
                insertion: .offset(x: 40),
                removal: .offset(x: 40)
              )
              .combined(with: .opacity)
            )
        }
      }
      .animation(.smoothSnappy, value: text.isEmpty)
      
      Button {
        send()
      } label: {
        Image(systemName: "paperplane")
          .resizable()
          .scaledToFit()
          .frame(width: 20, height: 20)
          .padding(8)
          .background(Color.accentColor)
          .clipShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .background(.regularMaterial)
  }
  
  private func handleEditorEvent(_ event: ComposeTextEditorEvent) {
    switch event {
    case .focus:
      focus.focusedField = .compose
      
    case .blur:
      focus.focusedField = nil
      
    case .returnKeyPress:
      // Single return creates a new line
      break
      
    case .commandReturnKeyPress:
      // Cmd+Return sends the message
      send()
      
    case .escapeKeyPress:
      // Clear focus and optionally clear text
      focus.focusedField = nil
    }
  }
  
  private func send() {
    print("send \(text)")
    Task {
      do {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let chatId = chatId else { return }
        
        let messageText = text
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
        
        scroller.scrollToBottom(animate: true)
        
        try await data.sendMessage(
          chatId: chatId,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          text: messageText,
          peerId: peerId,
          randomId: randomId
        )
        
      } catch {
        Log.shared.error("Failed to send message", error: error)
        // Optionally show error to user
      }
    }
  }
}

enum ComposeTextEditorEvent {
  case focus
  case blur
  case returnKeyPress
  case commandReturnKeyPress
  case escapeKeyPress
}

struct CustomTextEditor: NSViewRepresentable {
  @Binding var text: String
  var minHeight: CGFloat
  var maxHeight: CGFloat
  @Binding var height: CGFloat
  var onEvent: (ComposeTextEditorEvent) -> Void
  @Binding var isFocused: Bool

  var horizontalPadding: CGFloat = 8
  var verticalPadding: CGFloat = 6
  var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  
  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }
  
  func makeScrollView() -> NSScrollView {
    let scrollView = NSScrollView()
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
    let textView = NSTextView()

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

    let paragraphStyle = NSMutableParagraphStyle()
    let lineSpacing: CGFloat = 0.0
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.baseWritingDirection = .natural

    textView.typingAttributes = [
      .paragraphStyle: paragraphStyle, // H/T Daniel Jalkut
      .font: font, // Fall back to system font if we can't unwrap font argument
      .foregroundColor: NSColor.labelColor
    ]
    
    // Insets
    let lineHeight = textView.font?.boundingRectForFont.height ?? 0
    textView.textContainerInset = NSSize(
      width: 0,
      height: (minHeight - lineHeight) / 2
    )

    return textView
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
    if isFocused {
      if let firstResponder = textView.window?.firstResponder {
        if !firstResponder.isEqual(textView) {
          DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
          }
        }
      } else {
        DispatchQueue.main.async {
          textView.window?.makeFirstResponder(textView)
        }
      }
    } else {
      if let firstResponder = textView.window?.firstResponder, firstResponder.isEqual(textView) {
        DispatchQueue.main.async {
          textView.window?.makeFirstResponder(nil)
        }
      }
    }
  }
  
  class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CustomTextEditor
    var lastHeight: CGFloat = 0

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
    
    func calculateContentHeight(for textView: NSTextView) -> CGFloat {
      guard let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer else { return 0 }
      
      layoutManager.ensureLayout(for: textContainer)
      return layoutManager.usedRect(for: textContainer).height
    }
    
    func updateHeightIfNeeded(for textView: NSTextView) {
      let contentHeight = calculateContentHeight(for: textView)
      let lineHeight = textView.font?.boundingRectForFont.height ?? 0
      
      var newHeight = contentHeight + (parent.verticalPadding * 2)
      newHeight = max(parent.minHeight, min(parent.maxHeight, newHeight))
      
      print("newHeight \(newHeight)")
      // Enable vertical scrolling if content exceeds maxHeight
//      parent.scrollView.verticalScrollElasticity = contentHeight > parent.maxHeight ? .allowed : .none
      
//      if abs(newHeight - lastHeight) > 0.1 {
      lastHeight = newHeight
      parent.height = newHeight
    
      // Update insets based on content
      if contentHeight <= lineHeight {
        print("single line \(lineHeight)")
        textView.textContainerInset = NSSize(
          width: 0,
          height: (parent.minHeight - lineHeight) / 2
        )
      } else {
        textView.textContainerInset = NSSize(
          width: 0,
          height: parent.verticalPadding
        )
      }
//      }
    }
    
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      // Handle selection changes if needed
    }
    
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        print("Enter")
        if NSEvent.modifierFlags.contains(.command) {
          print("Enter + command")
          parent.onEvent(.commandReturnKeyPress)
          return true
        }
        parent.onEvent(.returnKeyPress)
//        updateHeightIfNeeded(for: textView)

        return false
        
      case #selector(NSResponder.cancelOperation(_:)):
        print("Esc")
        parent.onEvent(.escapeKeyPress)
        return true
        
      default:
        return false
      }
    }
    
    func textViewDidBecomeFirstResponder(_ notification: Notification) {
      parent.onEvent(.focus)
    }
    
    func textViewDidResignFirstResponder(_ notification: Notification) {
      parent.onEvent(.blur)
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
        insertNewline(self)
      } else {
        // Handle regular Enter key press (e.g., submit form)
        // You can customize this behavior
        if let delegate = delegate as? CustomTextViewDelegate {
          delegate.textViewDidPressReturn(self)
        }
      }
      return
    }
    
    super.keyDown(with: event)
  }
}

protocol CustomTextViewDelegate: NSTextViewDelegate {
  func textViewDidPressReturn(_ textView: NSTextView)
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
