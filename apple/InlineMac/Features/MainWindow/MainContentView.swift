import AppKit
import InlineKit
import SwiftUI

struct MainContentView: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @AppStorage(ReplyThreadPaneMetrics.preferredWidthDefaultsKey)
  private var preferredReplyThreadPaneWidth = Double(ReplyThreadPaneMetrics.idealContentWidth)
  @GestureState private var replyThreadPaneDragTranslation: CGFloat = 0
  @State private var replyThreadReveal = ReplyThreadPaneRevealAnimation()
  /// The pane peer that finished opening; nil while closed or mid-open.
  @State private var settledReplyThreadPeer: Peer?
  /// Keeps the outgoing pane mounted while it slides out.
  @State private var closingReplyThreadPeer: Peer?
  /// Route the pane is attached to. Leaving it (expand, back to another chat) drops the pane at once.
  @State private var replyThreadHostRoute: Nav3Route?
  @State private var hasAppeared = false

  /// The peer whose pane is on screen, including one that is still sliding out.
  private var displayedReplyThreadPeer: Peer? {
    nav.currentReplyThreadPeer ?? closingReplyThreadPeer ?? settledReplyThreadPeer
  }

  /// Fraction of the pane column that is revealed. Resolved synchronously from
  /// navigation state so the frame that commits a route change never pops the pane.
  private var replyThreadRevealFraction: CGFloat {
    if replyThreadReveal.isAnimating {
      return replyThreadReveal.progress
    }
    if nav.currentReplyThreadPeer != nil {
      // A restored route shows the pane on its first frame; a user open waits for the slide.
      return hasAppeared && settledReplyThreadPeer == nil ? 0 : 1
    }
    return settledReplyThreadPeer != nil ? 1 : 0
  }

  var body: some View {
    GeometryReader { geometry in
      let displayedReplyThreadPeer = displayedReplyThreadPeer
      let hasReplyThread = displayedReplyThreadPeer != nil && dependencies != nil
      let restingContentWidth = ReplyThreadPaneMetrics.contentWidth(
        for: geometry.size.width,
        preferredWidth: CGFloat(preferredReplyThreadPaneWidth)
      )
      let contentWidth = ReplyThreadPaneMetrics.contentWidth(
        for: geometry.size.width,
        preferredWidth: restingContentWidth - replyThreadPaneDragTranslation
      )
      let columnWidth = hasReplyThread
        ? ReplyThreadPaneMetrics.columnWidth(contentWidth: contentWidth) * replyThreadRevealFraction
        : 0
      let primaryWidth = max(0, geometry.size.width - columnWidth)

      HStack(spacing: 0) {
        RouteView(route: nav.currentRoute)
          .frame(
            minWidth: primaryWidth,
            maxWidth: primaryWidth,
            maxHeight: .infinity
          )
          .contentScrollEdgeEffect()

        if let replyThreadPeer = displayedReplyThreadPeer,
           let dependencies {
          ReplyThreadPaneColumn(
            peer: replyThreadPeer,
            dependencies: dependencies,
            contentWidth: contentWidth,
            revealedWidth: columnWidth,
            onExpand: {
              dependencies.openChatRoute(peer: replyThreadPeer)
            },
            onClose: {
              nav.closeReplyThread()
            }
          )
          .ignoresSafeArea(.all, edges: .vertical)
          .overlay(alignment: .leading) {
            ReplyThreadPaneDivider(
              contentWidth: contentWidth,
              onAccessibilityAdjust: { adjustment in
                persistReplyThreadPaneWidth(
                  contentWidth + adjustment,
                  availableWidth: geometry.size.width
                )
              }
            )
            .gesture(replyThreadResizeGesture(
              startWidth: restingContentWidth,
              availableWidth: geometry.size.width
            ))
          }
          .id(replyThreadPeer.toString())
        }
      }
      .frame(
        minWidth: geometry.size.width,
        maxWidth: geometry.size.width,
        minHeight: geometry.size.height,
        maxHeight: geometry.size.height,
        alignment: .leading
      )
    }
    .onAppear {
      settledReplyThreadPeer = nav.currentReplyThreadPeer
      replyThreadHostRoute = nav.currentRoute
      hasAppeared = true
    }
    .onChange(of: nav.currentReplyThreadPeer) { oldPeer, newPeer in
      replyThreadPeerChanged(from: oldPeer, to: newPeer)
    }
  }

  private func replyThreadPeerChanged(from oldPeer: Peer?, to newPeer: Peer?) {
    let window = NSApp.keyWindow
    // Only meaningful while a pane was showing; a closed pane has no host to leave.
    let routeChanged = oldPeer != nil && replyThreadHostRoute != nav.currentRoute
    replyThreadHostRoute = nav.currentRoute

    if routeChanged {
      // The primary chat is being replaced too; sliding over a different chat reads as a glitch.
      replyThreadReveal.reset(to: newPeer == nil ? 0 : 1)
      closingReplyThreadPeer = nil
      settledReplyThreadPeer = newPeer
      return
    }

    if let newPeer {
      closingReplyThreadPeer = nil
      guard settledReplyThreadPeer == nil else {
        // Switching threads keeps the column in place and swaps its content.
        settledReplyThreadPeer = newPeer
        return
      }
      replyThreadReveal.animate(to: 1, in: window) {
        settledReplyThreadPeer = nav.currentReplyThreadPeer
      }
      return
    }

    closingReplyThreadPeer = oldPeer ?? settledReplyThreadPeer
    settledReplyThreadPeer = nil
    replyThreadReveal.animate(to: 0, in: window) {
      guard nav.currentReplyThreadPeer == nil else { return }
      closingReplyThreadPeer = nil
    }
  }

  private func replyThreadResizeGesture(
    startWidth: CGFloat,
    availableWidth: CGFloat
  ) -> some Gesture {
    // Measure in the stable window coordinate space. Local coordinates move
    // with the divider as the pane resizes and make the drag feedback oscillate.
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .updating($replyThreadPaneDragTranslation) { value, translation, _ in
        translation = value.translation.width
      }
      .onEnded { value in
        persistReplyThreadPaneWidth(
          startWidth - value.translation.width,
          availableWidth: availableWidth
        )
      }
  }

  private func persistReplyThreadPaneWidth(_ width: CGFloat, availableWidth: CGFloat) {
    let clampedWidth = ReplyThreadPaneMetrics.contentWidth(
      for: availableWidth,
      preferredWidth: width
    )
    guard !preferredReplyThreadPaneWidth.isFinite
      || abs(preferredReplyThreadPaneWidth - Double(clampedWidth)) >= 0.5
    else { return }
    preferredReplyThreadPaneWidth = Double(clampedWidth)
  }
}

private struct ReplyThreadPaneDivider: View {
  let contentWidth: CGFloat
  let onAccessibilityAdjust: (CGFloat) -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .leading) {
      Color.clear

      Rectangle()
        .fill(Color(nsColor: .separatorColor).opacity(isHovered ? 0.42 : 0.16))
        .frame(width: ReplyThreadPaneMetrics.separatorWidth)
    }
    .frame(width: 8)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .onHover(perform: updateHover)
    .onDisappear(perform: resetCursor)
    .accessibilityElement()
    .accessibilityLabel("Reply thread pane width")
    .accessibilityValue("\(Int(contentWidth.rounded())) points")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        onAccessibilityAdjust(20)
      case .decrement:
        onAccessibilityAdjust(-20)
      @unknown default:
        break
      }
    }
  }

  private func updateHover(_ hovering: Bool) {
    guard hovering != isHovered else { return }
    isHovered = hovering
    if hovering {
      NSCursor.resizeLeftRight.push()
    } else {
      NSCursor.pop()
    }
  }

  private func resetCursor() {
    guard isHovered else { return }
    isHovered = false
    NSCursor.pop()
  }
}

private struct ReplyThreadPaneColumn: View {
  let peer: Peer
  let dependencies: AppDependencies
  let contentWidth: CGFloat
  let revealedWidth: CGFloat
  let onExpand: () -> Void
  let onClose: () -> Void

  var body: some View {
    let columnWidth = ReplyThreadPaneMetrics.columnWidth(contentWidth: contentWidth)
    let visibleWidth = min(max(revealedWidth, 0), columnWidth)

    // The inner column always lays out at its target width. Animating only this
    // outer clipped width later will avoid reflowing the embedded chat each frame.
    HStack(spacing: 0) {
      Color.clear
        .frame(width: ReplyThreadPaneMetrics.separatorWidth)

      ReplyThreadPaneView(
        peer: peer,
        dependencies: dependencies,
        onExpand: onExpand,
        onClose: onClose
      )
      .frame(
        minWidth: contentWidth,
        maxWidth: contentWidth,
        maxHeight: .infinity
      )
    }
    .frame(
      minWidth: columnWidth,
      maxWidth: columnWidth,
      maxHeight: .infinity,
      alignment: .leading
    )
    .frame(
      minWidth: visibleWidth,
      maxWidth: visibleWidth,
      maxHeight: .infinity,
      alignment: .leading
    )
    .clipped()
  }
}

private extension View {
  @ViewBuilder
  func contentScrollEdgeEffect() -> some View {
    if #available(macOS 27.0, *) {
      // Disabled on macOS 27 while investigating AppKit/SwiftUI stack overflows on app open.
      self
    } else if #available(macOS 26.0, *) {
      scrollEdgeEffectStyle(.soft, for: .all)
    } else {
      self
    }
  }
}

#Preview {
  MainContentView()
    .environment(\.nav, {
      let nav = Nav3()
      let parentPeer = Peer.thread(id: 1)
      nav.open(.chat(peer: parentPeer))
      nav.openReplyThread(parentPeer: parentPeer, threadPeer: .thread(id: 2))
      return nav
    }())
    .appDatabase(.populated())
    .environment(dependencies: AppDependencies())
}
