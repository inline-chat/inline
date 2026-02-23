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
  private var keyDownMonitor: Any?
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
    setupKeyDownMonitor()
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
    guard let hostingView else { return }

    let windowSize = hostingView.fittingSize
    let cursorLocation = NSEvent.mouseLocation
    let bottomGapFromCursor: CGFloat = 6

    let preferredX = cursorLocation.x - (windowSize.width / 2)
    let preferredY = cursorLocation.y + bottomGapFromCursor

    let targetScreen = screen(containing: cursorLocation)
      ?? messageView.window?.screen
      ?? NSScreen.main
    guard let visibleFrame = targetScreen?.visibleFrame else { return }

    // Clamp into the current screen so the picker stays fully visible near edges.
    let finalX = min(max(preferredX, visibleFrame.minX), visibleFrame.maxX - windowSize.width)
    let finalY = min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - windowSize.height)

    setFrame(
      NSRect(x: finalX, y: finalY, width: windowSize.width, height: windowSize.height),
      display: true
    )
  }

  private func screen(containing point: NSPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(point) }
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

  private func setupKeyDownMonitor() {
    keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      guard event.keyCode == 53 else { return event } // Esc
      closeWithAnimation()
      return nil
    }
  }

  private func removeEventMonitors() {
    if let monitor = mouseDownMonitor {
      NSEvent.removeMonitor(monitor)
      mouseDownMonitor = nil
    }
    if let monitor = keyDownMonitor {
      NSEvent.removeMonitor(monitor)
      keyDownMonitor = nil
    }
  }

  override func close() {
    removeEventMonitors()
    super.close()
  }

  deinit {
    removeEventMonitors()
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

extension MinimalMessageViewAppKit {
  func showReactionOverlay() {
    // Don't show reactions for messages that are still sending
    guard fullMessage.message.status != .sending else { return }

    let overlayWindow = ReactionOverlayWindow(
      messageView: self,
      fullMessage: fullMessage
    )

    overlayWindow.ignoresMouseEvents = false
    overlayWindow.contentView?.wantsLayer = true
    overlayWindow.makeKeyAndOrderFront(nil)
  }
}
