import InlineKit
import InlineUI
import SwiftUI

enum ReplyThreadPaneMetrics {
  static let preferredWidthDefaultsKey = "replyThreadPanePreferredWidth"
  static let minimumContentWidth = Theme.chatViewMinWidth
  static let idealContentWidth: CGFloat = 380
  static let minimumPrimaryContentWidth = Theme.chatViewMinWidth
  static let separatorWidth: CGFloat = 0.5
  static let floatingToolbarHeight: CGFloat = 34
  static let floatingToolbarTopSpacing: CGFloat = 8
  static let floatingToolbarBottomSpacing: CGFloat = 8
  static let floatingToolbarContentInset = floatingToolbarTopSpacing
    + floatingToolbarHeight
    + floatingToolbarBottomSpacing

  static func contentWidth(for availableWidth: CGFloat, preferredWidth: CGFloat) -> CGFloat {
    let sanitizedPreferredWidth = preferredWidth.isFinite ? preferredWidth : idealContentWidth
    let maximumContentWidth = max(
      minimumContentWidth,
      availableWidth - minimumPrimaryContentWidth - separatorWidth
    )
    return min(max(sanitizedPreferredWidth, minimumContentWidth), maximumContentWidth)
  }

  static func columnWidth(contentWidth: CGFloat) -> CGFloat {
    contentWidth + separatorWidth
  }

  static func minimumWindowWidth(isSidebarCollapsed: Bool) -> CGFloat {
    minimumPrimaryContentWidth
      + minimumContentWidth
      + separatorWidth
      + (isSidebarCollapsed ? 0 : Theme.maximumSidebarWidth)
  }
}

struct ReplyThreadPaneView: View {
  let peer: Peer
  let dependencies: AppDependencies
  let onExpand: () -> Void
  let onClose: () -> Void

  @State private var toolbarState = ChatToolbarState()
  @State private var titleModel: ChatRouteToolbarTitleModel

  init(
    peer: Peer,
    dependencies: AppDependencies,
    onExpand: @escaping () -> Void,
    onClose: @escaping () -> Void
  ) {
    self.peer = peer
    self.dependencies = dependencies
    self.onExpand = onExpand
    self.onClose = onClose
    _titleModel = State(initialValue: ChatRouteToolbarTitleModel(
      peer: peer,
      db: dependencies.database
    ))
  }

  var body: some View {
    let appearance = ChatViewAppearance(
      surfaceStyle: .replyThread,
      additionalTopContentInset: ReplyThreadPaneMetrics.floatingToolbarContentInset
    )

    ReplyThreadPaneChatView(
      peer: peer,
      dependencies: dependencies,
      toolbarState: toolbarState,
      appearance: appearance
    )
    .overlay {
      GeometryReader { geometry in
        ReplyThreadPaneControls(
          peer: peer,
          dependencies: dependencies,
          title: titleModel.title,
          iconPeer: titleModel.iconPeer,
          onExpand: onExpand,
          onClose: onClose
        )
          .padding(
            .top,
            geometry.safeAreaInsets.top + Theme.toolbarHeight
              + ReplyThreadPaneMetrics.floatingToolbarTopSpacing
          )
          .padding(.horizontal, 8)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
    }
    .modifier(ChatToolbarParticipantsTitlePresentations(
      peer: peer,
      dependencies: dependencies,
      toolbarState: toolbarState
    ))
    .onDisappear {
      toolbarState.dismissPresentation()
    }
  }
}

private struct ReplyThreadPaneControls: View {
  let peer: Peer
  let dependencies: AppDependencies
  let title: String
  let iconPeer: ChatIcon.PeerType?
  let onExpand: () -> Void
  let onClose: () -> Void

  var body: some View {
    let shape = Capsule()
    let content = HStack(spacing: 4) {
      HStack(spacing: 7) {
        if let iconPeer {
          SidebarChatIcon(peer: iconPeer, size: 20)
        } else {
          ThreadIconView(
            ThreadIconDescriptor(emoji: nil, isReplyThread: true),
            size: .compact(20)
          )
        }

        Text(title)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)

      Divider()
        .frame(height: 18)

      ReplyThreadPaneControlButton(
        systemImage: "xmark",
        help: "Close Thread",
        accessibilityLabel: "Close Thread",
        action: onClose
      )

      Divider()
        .frame(height: 18)

      ReplyThreadPaneControlButton(
        systemImage: "arrow.up.left.and.arrow.down.right",
        help: "Open as Chat",
        accessibilityLabel: "Open Thread as Chat",
        action: onExpand
      )

      Divider()
        .frame(height: 18)

      ChatToolbarMenuButton(peer: peer, dependencies: dependencies)
        .buttonStyle(.plain)
        .controlSize(.small)
        .frame(width: 26, height: 26)
    }
    .padding(4)
    .frame(height: ReplyThreadPaneMetrics.floatingToolbarHeight)

    if #available(macOS 26.0, *) {
      content
        .glassEffect(.regular, in: shape)
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .overlay {
          shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
  }
}

private struct ReplyThreadPaneControlButton: View {
  let systemImage: String
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 26)
        .background {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        }
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .focusable(false)
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .onHover { isHovered = $0 }
  }
}

private struct ReplyThreadPaneChatView: View {
  let peer: Peer
  let dependencies: AppDependencies
  let toolbarState: ChatToolbarState
  let appearance: ChatViewAppearance

  var body: some View {
    AppKitRouteViewController<ChatViewAppKit>(
      make: {
        ChatViewAppKit(
          peerId: peer,
          dependencies: dependencies,
          appearance: appearance,
          toolbarState: toolbarState
        )
      },
      dismantle: { controller in
        controller.dispose()
      }
    )
    .ignoresSafeArea(.all, edges: .vertical)
    .background(Color(nsColor: appearance.surfaceBackgroundColor))
    // TODO: macOS 27 currently associates the native window-toolbar scroll-edge
    // background with the primary ChatRoute's AppKit scroll view. Revisit when
    // SwiftUI can share that toolbar treatment with a secondary AppKit chat.
    .chatScrollEdgeEffect()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
