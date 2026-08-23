import InlineKit
import InlineUI
import SwiftUI

enum ReplyThreadPaneMetrics {
  static let preferredWidthDefaultsKey = "replyThreadPanePreferredWidth"
  static let minimumContentWidth = Theme.chatViewMinWidth
  static let idealContentWidth: CGFloat = 380
  static let nativeInspectorMinimumWidth: CGFloat = 330
  static let minimumPrimaryContentWidth = Theme.chatViewMinWidth
  static let separatorWidth: CGFloat = 0.5
  static let floatingToolbarHeight: CGFloat = 40
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

  static func minimumWindowWidth(
    isSidebarCollapsed: Bool,
    replyPaneMinimumWidth: CGFloat = minimumContentWidth
  ) -> CGFloat {
    minimumPrimaryContentWidth
      + replyPaneMinimumWidth
      + separatorWidth
      + (isSidebarCollapsed ? 0 : Theme.maximumSidebarWidth)
  }
}

enum ReplyThreadPaneChrome: Equatable {
  case floating
  case nativeInspector
}

struct ReplyThreadPaneView: View {
  let peer: Peer
  let dependencies: AppDependencies
  let chrome: ReplyThreadPaneChrome
  let showsNativeToolbar: Bool
  let onExpand: () -> Void
  let onClose: () -> Void

  @State private var toolbarState = ChatToolbarState()
  @State private var botChatSettingsCoordinator: BotChatSettingsCoordinator
  @State private var titleModel: ChatRouteToolbarTitleModel

  init(
    peer: Peer,
    dependencies: AppDependencies,
    chrome: ReplyThreadPaneChrome,
    showsNativeToolbar: Bool,
    onExpand: @escaping () -> Void,
    onClose: @escaping () -> Void
  ) {
    self.peer = peer
    self.dependencies = dependencies
    self.chrome = chrome
    self.showsNativeToolbar = showsNativeToolbar
    self.onExpand = onExpand
    self.onClose = onClose
    _botChatSettingsCoordinator = State(initialValue: BotChatSettingsCoordinator(peer: peer))
    _titleModel = State(initialValue: ChatRouteToolbarTitleModel(
      peer: peer,
      db: dependencies.database
    ))
  }

  var body: some View {
    let appearance = ChatViewAppearance(
      surfaceStyle: .replyThread,
      isTransparent: chrome == .nativeInspector,
      additionalTopContentInset: chrome == .floating
        ? ReplyThreadPaneMetrics.floatingToolbarContentInset
        : 0
    )

    ReplyThreadPaneChatView(
      peer: peer,
      dependencies: dependencies,
      toolbarState: toolbarState,
      appearance: appearance,
      usesInspectorSizingIsolation: chrome == .nativeInspector
    )
    .overlay {
      if chrome == .floating {
        GeometryReader { geometry in
          ReplyThreadPaneControls(
            title: titleModel.title,
            status: titleModel.status,
            botChatSettingsCoordinator: botChatSettingsCoordinator,
            toolbarState: toolbarState,
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
    }
    .toolbar {
      if chrome == .nativeInspector, showsNativeToolbar {
        ReplyThreadInspectorToolbar(
          title: titleModel.title,
          status: titleModel.status,
          onExpand: onExpand,
          onClose: onClose
        )
      }
    }
    .modifier(ChatToolbarParticipantsTitlePresentations(
      peer: peer,
      dependencies: dependencies,
      toolbarState: toolbarState
    ))
    .task(id: peer.toString(), priority: .utility) {
      botChatSettingsCoordinator.startObservingDiscoveryScope(in: dependencies.database)
      await botChatSettingsCoordinator.warmUp()
    }
    .onDisappear {
      toolbarState.dismissPresentation()
      botChatSettingsCoordinator.cancel()
    }
  }
}

private struct ReplyThreadInspectorToolbar: ToolbarContent {
  let title: String
  let status: ChatRouteToolbarTitleModel.Status
  let onExpand: () -> Void
  let onClose: () -> Void

  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .primaryAction) {
        expandButton
      }

      ToolbarItem(placement: .primaryAction) {
        ReplyThreadInspectorTitle(title: title, status: status)
      }

      ToolbarSpacer(.flexible, placement: .primaryAction)

      ToolbarItem(placement: .primaryAction) {
        closeButton
      }
    } else {
      ToolbarItem(placement: .primaryAction) {
        HStack {
          expandButton
          ReplyThreadInspectorTitle(title: title, status: status)
          Spacer()
          closeButton
        }
        .frame(width: ReplyThreadPaneMetrics.nativeInspectorMinimumWidth - 30)
      }
    }
  }

  private var expandButton: some View {
    Button(action: onExpand) {
      Label("Open Thread as Chat", systemImage: "arrow.up.left.and.arrow.down.right")
    }
    .labelStyle(.iconOnly)
    .help("Open as Chat")
  }

  private var closeButton: some View {
    Button(action: onClose) {
      Label("Close Thread", systemImage: "xmark")
    }
    .labelStyle(.iconOnly)
    .help("Close Thread")
  }
}

private struct ReplyThreadInspectorTitle: View {
  let title: String
  let status: ChatRouteToolbarTitleModel.Status

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)

      if let statusText = status.text {
        HStack(spacing: 3) {
          if status.isTyping {
            TypingActivityIndicator(
              dotSize: 2,
              spacing: 1,
              color: .accentColor,
              lift: 1
            )
          } else if status.isRecordingVoice {
            VoiceRecordingActivityIndicator(
              barWidth: 1,
              spacing: 1,
              minBarHeight: 2,
              maxBarHeight: 6,
              color: .accentColor
            )
          }

          Text(statusText)
            .font(.system(size: 9))
            .foregroundStyle(status.usesAccentColor ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
    }
    .frame(minWidth: 0, idealWidth: 140, maxWidth: 180, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct ReplyThreadPaneControls: View {
  let title: String
  let status: ChatRouteToolbarTitleModel.Status
  let botChatSettingsCoordinator: BotChatSettingsCoordinator
  let toolbarState: ChatToolbarState
  let onExpand: () -> Void
  let onClose: () -> Void

  var body: some View {
    let shape = Capsule()
    let content = HStack(spacing: 2) {
      ReplyThreadPaneControlButton(
        systemImage: "arrow.up.left.and.arrow.down.right",
        help: "Open as Chat",
        accessibilityLabel: "Open Thread as Chat",
        action: onExpand
      )

      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)

        if status.isTyping, let typingText = status.text {
          HStack(spacing: 3) {
            TypingActivityIndicator(
              dotSize: 2,
              spacing: 1,
              color: .accentColor,
              lift: 1
            )

            Text(typingText)
              .font(.system(size: 9))
              .foregroundStyle(Color.accentColor)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)

      if botChatSettingsCoordinator.isToolbarVisible {
        BotChatSettingsToolbarButton(
          coordinator: botChatSettingsCoordinator,
          toolbarState: toolbarState
        )
        .buttonStyle(ReplyThreadPaneControlButtonStyle())
      }

      ReplyThreadPaneControlButton(
        systemImage: "xmark",
        help: "Close Thread",
        accessibilityLabel: "Close Thread",
        action: onClose
      )
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

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
    }
    .buttonStyle(ReplyThreadPaneControlButtonStyle())
    .focusable(false)
    .help(help)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct ReplyThreadPaneControlButtonStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: 11, weight: .medium))
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(Color.secondary)
      .frame(width: 26, height: 26)
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : (isHovered ? 0.08 : 0)))
      }
      .contentShape(.interaction, RoundedRectangle(cornerRadius: 6, style: .continuous))
      .onHover { isHovered = $0 }
  }
}

private struct ReplyThreadPaneChatView: View {
  let peer: Peer
  let dependencies: AppDependencies
  let toolbarState: ChatToolbarState
  let appearance: ChatViewAppearance
  let usesInspectorSizingIsolation: Bool

  var body: some View {
    if usesInspectorSizingIsolation {
      GeometryReader { geometry in
        ReplyThreadPaneAppKitChat(
          peer: peer,
          dependencies: dependencies,
          toolbarState: toolbarState,
          appearance: appearance
        )
        .frame(width: geometry.size.width, height: geometry.size.height)
      }
    } else {
      ReplyThreadPaneAppKitChat(
        peer: peer,
        dependencies: dependencies,
        toolbarState: toolbarState,
        appearance: appearance
      )
    }
  }
}

private struct ReplyThreadPaneAppKitChat: View {
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
