import AppKit
import Auth
import InlineKit
import Logger
import SwiftUI

// MARK: - Reaction Overlay Window

class ReactionOverlayWindow: NSPanel {
  private var hostingView: NSHostingView<ReactionOverlayView>?
  private var messageView: NSView
  private var mouseDownMonitor: Any?
  private var fullMessage: FullMessage

  init(messageView: NSView, fullMessage: FullMessage) {
    self.messageView = messageView
    self.fullMessage = fullMessage

    // Configure window
    super.init(
      contentRect: .zero,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    // Create the SwiftUI view
    let overlayView = ReactionOverlayView(
      fullMessage: fullMessage,
      onDismiss: { [weak self] in
        self?.closeWithAnimation()
      }
    )

    // Initialize hosting view
    hostingView = NSHostingView(rootView: overlayView)

    // Make window transparent and floating
    isOpaque = false
    backgroundColor = .clear
    level = .floating
    hasShadow = false
    isMovable = false
    isMovableByWindowBackground = false
    ignoresMouseEvents = false

    // Add the hosting view
    contentView = hostingView

    // Make sure the window can receive mouse events
    contentView?.wantsLayer = true
    contentView?.acceptsTouchEvents = true

    // Position the window
    positionWindow()

    // Add mouse down monitor to dismiss on click outside
    setupMouseDownMonitor()
  }
  
  private func closeWithAnimation() {
    guard let hostingView else { return }

    // Animate the closing of the window
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.15
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

      hostingView.animator().alphaValue = 0
    }) {
      self.close()
    }
  }
    

  private func positionWindow() {
    guard let screen = messageView.window?.screen else { return }

    // Convert message view frame to screen coordinates
    let messageFrame = messageView.convert(messageView.bounds, to: nil)
    let windowFrame = messageView.window?.convertPoint(toScreen: messageFrame.origin) ?? .zero

    // Position above the message
    let windowSize = hostingView!.fittingSize
    let x = windowFrame.x - (windowSize.width - messageFrame.width) / 2
    let y = windowFrame.y + messageFrame.height + 5 // 5 points gap

    // Ensure window stays on screen
    let screenFrame = screen.visibleFrame
    let finalX = min(max(x, screenFrame.minX), screenFrame.maxX - windowSize.width)
    let finalY = min(max(y, screenFrame.minY), screenFrame.maxY - windowSize.height)

    setFrame(NSRect(x: finalX, y: finalY, width: windowSize.width, height: windowSize.height), display: true)
  }

  private func setupMouseDownMonitor() {
    mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self else { return event }

      // Convert the event location to window coordinates
      let location = event.locationInWindow

      // Check if click is outside our content view
      if let contentView, !contentView.frame.contains(location) {
        closeWithAnimation()
      }
      return event
    }
  }

  deinit {
    if let monitor = mouseDownMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}

// MARK: - Reaction Overlay View

// struct ReactionOverlayView: View {
//  let fullMessage: FullMessage
//  let onDismiss: () -> Void
//
//  // Common emoji reactions
//  static let defaultReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
//
//  // State for hover and animation
//  @State private var isHovered: [String: Bool] = [:]
//  @State private var appearScale: CGFloat = 0.8
//  @State private var appearOpacity: Double = 0
//
//  private func handleReactionSelected(_ emoji: String) {
//    // Check if user already reacted with this emoji
//    let currentUserId = Auth.shared.getCurrentUserId() ?? 0
//    let hasReaction = fullMessage.reactions.contains {
//      $0.emoji == emoji && $0.userId == currentUserId
//    }
//
//    if hasReaction {
//      // Remove reaction
//      Transactions.shared.mutate(transaction: .deleteReaction(.init(
//        message: fullMessage.message,
//        emoji: emoji,
//        peerId: fullMessage.message.peerId,
//        chatId: fullMessage.message.chatId
//      )))
//    } else {
//      // Add reaction
//      Transactions.shared.mutate(transaction: .addReaction(.init(
//        message: fullMessage.message,
//        emoji: emoji,
//        userId: currentUserId,
//        peerId: fullMessage.message.peerId
//      )))
//    }
//
//    // Dismiss the overlay
//    onDismiss()
//  }
//
//  var body: some View {
//    HStack(spacing: 8) {
//      ForEach(Self.defaultReactions, id: \.self) { emoji in
//        Button(action: {
//          handleReactionSelected(emoji)
//        }) {
//          Text(emoji)
//            .font(.system(size: 24))
//        }
//        .buttonStyle(.plain)
//        .padding(8)
//        .background(
//          RoundedRectangle(cornerRadius: 8)
//            .fill(Color(NSColor.windowBackgroundColor).opacity(0.8))
//            .overlay(
//              RoundedRectangle(cornerRadius: 8)
//                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
//            )
//        )
//        .scaleEffect(isHovered[emoji] == true ? 1.1 : 1.0)
//        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered[emoji])
//        .onHover { hovering in
//          isHovered[emoji] = hovering
//        }
//      }
//    }
//    .padding(8)
//    .background(
//      RoundedRectangle(cornerRadius: 12)
//        .fill(Color(NSColor.windowBackgroundColor).opacity(0.9))
//        .overlay(
//          RoundedRectangle(cornerRadius: 12)
//            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
//        )
//    )
//    .scaleEffect(appearScale)
//    .opacity(appearOpacity)
//    .onAppear {
//      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
//        appearScale = 1.0
//        appearOpacity = 1.0
//      }
//    }
//  }
// }


// MARK: - Message View Extension

extension MessageViewAppKit {
  func showReactionOverlay() {
    // Don't show reactions for messages that are still sending
    guard fullMessage.message.status != .sending else { return }

    // Create and show the overlay window
    let overlayWindow = ReactionOverlayWindow(
      messageView: self,
      fullMessage: fullMessage
    )

    // Make sure the window can receive mouse events
    overlayWindow.ignoresMouseEvents = false
    overlayWindow.contentView?.wantsLayer = true

    overlayWindow.makeKeyAndOrderFront(nil)
  }
}
