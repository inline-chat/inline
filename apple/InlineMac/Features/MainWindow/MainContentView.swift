import AppKit
import InlineKit
import SwiftUI

struct MainContentView: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @AppStorage(ReplyThreadPaneMetrics.preferredWidthDefaultsKey)
  private var preferredReplyThreadPaneWidth = Double(ReplyThreadPaneMetrics.idealContentWidth)
  @GestureState private var replyThreadPaneDragTranslation: CGFloat = 0

  var body: some View {
    GeometryReader { geometry in
      let hasReplyThread = nav.currentReplyThreadPeer != nil && dependencies != nil
      let restingContentWidth = ReplyThreadPaneMetrics.contentWidth(
        for: geometry.size.width,
        preferredWidth: CGFloat(preferredReplyThreadPaneWidth)
      )
      let contentWidth = ReplyThreadPaneMetrics.contentWidth(
        for: geometry.size.width,
        preferredWidth: restingContentWidth - replyThreadPaneDragTranslation
      )
      let columnWidth = hasReplyThread
        ? ReplyThreadPaneMetrics.columnWidth(contentWidth: contentWidth)
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

        if let replyThreadPeer = nav.currentReplyThreadPeer,
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
