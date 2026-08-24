import InlineKit
import InlineMacUI
import InlineUI
import Logger
import SwiftUI

enum SidebarItemSize: String, CaseIterable, Identifiable {
  case compact
  case standard

  var id: String { rawValue }

  var title: LocalizedStringResource {
    switch self {
    case .compact:
      "Compact"
    case .standard:
      "Standard"
    }
  }

  var detail: LocalizedStringResource {
    switch self {
    case .compact:
      "Single-line rows"
    case .standard:
      "One-line message preview"
    }
  }

  var rowHeight: CGFloat {
    switch self {
    case .compact:
      30
    case .standard:
      44
    }
  }

  var iconSize: CGFloat {
    switch self {
    case .compact:
      22
    case .standard:
      32
    }
  }
}

/// Shared SwiftUI/AppKit geometry for chat hierarchy. Direct reply titles align
/// with their icon-bearing parent title, while deeper replies retain the
/// existing compact 16-point hierarchy step.
enum SidebarChatRowLayout {
  static let hierarchyIndent: CGFloat = 16
  static let unreadDotTextSpacing: CGFloat = 8

  static func contentIndentation(
    level: Int,
    size: SidebarItemSize,
    showsIcon: Bool
  ) -> CGFloat {
    let level = max(level, 0)
    let base = CGFloat(level) * hierarchyIndent
    guard level > 0, !showsIcon else { return base }

    let parentTitleOffset = size.iconSize + 8
    return base + parentTitleOffset - hierarchyIndent
  }

  static func unreadDotLeadingSpacing(
    contentLeadingSpacing: CGFloat,
    isNestedThread: Bool
  ) -> CGFloat {
    guard isNestedThread else { return Theme.sidebarItemUnreadDotLeadingSpacing }
    return contentLeadingSpacing - Theme.sidebarItemUnreadDotSize - unreadDotTextSpacing
  }
}

struct SidebarChatFolderMenu {
  struct Destination: Identifiable {
    let id: Int64
    let title: String
    let move: () -> Void
  }

  let destinations: [Destination]
  let create: () -> Void
  let removeFromFolder: (() -> Void)?
}

struct SidebarChatItemView: Equatable, View {
  let item: SidebarViewModel.Item
  let selected: Bool
  var titleDimmed = false
  var size: SidebarItemSize = .standard
  var unreadBadgeStyle: UnreadBadgeStyle = .defaultValue
  var showsCloseButton = false
  var opensOnMouseDown = true
  var allowsHoverEffects = true
  var forceHoverAppearance = false
  var isTemporary = false
  var isDropTargeted = false
  var indentationLevel = 0
  var showsIcon = true
  var disclosureExpanded: Bool?
  var usesFullWidthCollectionLayout = false
  var onOpen: (() -> Void)?
  var onClose: (() -> Void)?
  var onPersist: (() -> Void)?
  var onToggleDisclosure: (() -> Void)?
  var folderMenu: (() -> SidebarChatFolderMenu?)?

  // Env and State
  @Environment(\.nav) private var nav
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dependencies) private var dependencies
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false
  @State private var isCloseHovered = false
  @State private var isDisclosureHovered = false
  @State private var isPressing = false
  @State private var showRenameSheet = false

  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private static let replyThreadTitleFont: Font = .system(size: 12, weight: .regular)
  private static let parentTitleFont: Font = .system(size: 10, weight: .regular)
  private static let subtitleFont: Font = .system(size: 11)
  private static let trailingAccessoryMinWidth = 14.0
  private static let showsParentChatTitle = false

  // Computed
  private var rowHeight: CGFloat {
    size.rowHeight
  }

  private var iconSize: CGFloat {
    size.iconSize
  }

  private var peerId: Peer {
    item.peerId
  }

  private var showsPreview: Bool {
    size != .compact && visibleParentTitle == nil
  }

  private var titleAccessory: SidebarChatItemAccessory? {
    guard unreadBadgeStyle == .numbered else { return nil }

    if item.unread, showsPreview {
      return nil
    }

    if item.unread {
      return .unread
    }

    return nil
  }

  private var previewAccessory: SidebarChatItemAccessory? {
    guard unreadBadgeStyle == .numbered else { return nil }
    guard item.unread, showsPreview else { return nil }
    return .unread
  }

  private var visibleParentTitle: String? {
    guard Self.showsParentChatTitle else { return nil }
    return item.parentTitle
  }

  private var contentLeadingSpacing: CGFloat {
    Theme.sidebarItemInnerSpacing + SidebarChatRowLayout.contentIndentation(
      level: indentationLevel,
      size: size,
      showsIcon: showsIcon
    )
  }

  private var unreadDotLeadingSpacing: CGFloat {
    SidebarChatRowLayout.unreadDotLeadingSpacing(
      contentLeadingSpacing: contentLeadingSpacing,
      isNestedThread: indentationLevel > 0 && !showsIcon
    )
  }

  static func == (lhs: SidebarChatItemView, rhs: SidebarChatItemView) -> Bool {
    lhs.item == rhs.item
      && lhs.selected == rhs.selected
      && lhs.titleDimmed == rhs.titleDimmed
      && lhs.size == rhs.size
      && lhs.unreadBadgeStyle == rhs.unreadBadgeStyle
      && lhs.showsCloseButton == rhs.showsCloseButton
      && lhs.opensOnMouseDown == rhs.opensOnMouseDown
      && lhs.allowsHoverEffects == rhs.allowsHoverEffects
      && lhs.forceHoverAppearance == rhs.forceHoverAppearance
      && lhs.isTemporary == rhs.isTemporary
      && lhs.isDropTargeted == rhs.isDropTargeted
      && lhs.indentationLevel == rhs.indentationLevel
      && lhs.showsIcon == rhs.showsIcon
      && lhs.disclosureExpanded == rhs.disclosureExpanded
      && lhs.usesFullWidthCollectionLayout == rhs.usesFullWidthCollectionLayout
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if unreadBadgeStyle == .dot {
        unreadBadge
          .padding(.leading, unreadDotLeadingSpacing)
          .opacity(showsDisclosureControl ? 0 : 1)
      }

      HStack(spacing: 0) {
        if showsIcon {
          avatar
            .frame(width: iconSize, height: iconSize)
            .padding(.trailing, 8)
            .transition(.opacity)
        }

        VStack(alignment: .leading, spacing: 2) {
          titleBlock

          if showsPreview {
            HStack(spacing: 5) {
              SidebarComposeActivityPreview(
                peer: peerId,
                preview: item.preview,
                font: Self.subtitleFont
              )
              .id(peerId)

              if let previewAccessory {
                accessoryView(previewAccessory)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, contentLeadingSpacing)
      .padding(.trailing, Theme.sidebarItemOuterSpacing)

      if disclosureExpanded != nil {
        disclosureButton
          .opacity(showsDisclosureControl ? 1 : 0)
          .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.14),
            value: showsDisclosureControl
          )
          // Keep the generous invisible target active so entering from the
          // collection's leading edge can reveal the tiny visual chevron.
          .allowsHitTesting(true)
      }
    }
    .frame(height: SidebarCollectionRow.paintedItemHeight(for: rowHeight))
    .animation(.smoothSnappy, value: size)
    .animation(reduceMotion ? nil : SidebarDisclosureMotion.animation, value: indentationLevel)
    .animation(reduceMotion ? nil : SidebarDisclosureMotion.animation, value: showsIcon)
    .animation(.smoothSnappy, value: item.unread)
    .animation(.smoothSnappy, value: item.unreadCount)
    .animation(.smoothSnappy, value: item.unreadMark)
    .animation(.smoothSnappy, value: item.prominentUnreadDot)
    .animation(.smoothSnappy, value: unreadBadgeStyle)
    .animation(.smoothSnappy, value: item.pinned)
    .background(background)
    // Outer paddings
    .padding(.horizontal, outerHorizontalPadding)
    .padding(.vertical, SidebarCollectionRow.itemVisualEdgeInset)
    .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
    .onHover {
      guard allowsHoverEffects else { return }
      isHovered = $0
      if $0 == false {
        isCloseHovered = false
        isDisclosureHovered = false
      }
    }
    .modifier(SidebarOpenInteractionModifier(
      opensOnMouseDown: opensOnMouseDown,
      isControlHovered: isCloseHovered || isDisclosureHovered,
      isPressing: $isPressing,
      open: open
    ))
    .simultaneousGesture(TapGesture(count: 2).onEnded {
      guard item.parentChatId != nil else { return }
      guard isCloseHovered == false, isDisclosureHovered == false else { return }
      showRenameSheet = true
    })
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityTitle)
    .accessibilityValue(accessibilityUnreadValue)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAction {
      open()
    }
    .contextMenu {
      Button {
        MainWindowOpenCoordinator.shared.openTab(.chat(peer: peerId))
      } label: {
        Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
      }

      Button {
        MainWindowOpenCoordinator.shared.openNewWindow(.chat(peer: peerId))
      } label: {
        Label("Open in New Window", systemImage: "macwindow")
      }

      if item.parentChatId != nil {
        Button {
          showRenameSheet = true
        } label: {
          Label("Rename Thread...", systemImage: "pencil")
        }
      }

      Divider()

      if isTemporary {
        if showsCloseButton {
          Button {
            close()
          } label: {
            Label("Close from Sidebar", systemImage: "xmark")
          }

          Divider()
        }

        Button {
          persist()
        } label: {
          Label("Keep in Sidebar", systemImage: "sidebar.left")
        }
      }

      if isTemporary == false {
        if showsCloseButton {
          Button {
            close()
          } label: {
            Label("Close from Sidebar", systemImage: "xmark")
          }

          Divider()
        }

        if item.pinned || item.folderID == nil {
          Button {
            togglePin()
          } label: {
            Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash.fill" : "pin.fill")
          }
        }

        Button {
          toggleReadUnread()
        } label: {
          Label(
            item.unread ? "Mark Read" : "Mark Unread",
            systemImage: item.unread ? "checkmark.message.fill" : "envelope.badge.fill"
          )
        }

        if let folderMenu = folderMenu?() {
          Divider()

          Menu("Move to Folder", systemImage: "folder") {
            ForEach(folderMenu.destinations) { destination in
              Button(destination.title, action: destination.move)
            }
            if folderMenu.destinations.isEmpty {
              Text("No other folders")
            }
          }

          Button("New Folder with Chat", systemImage: "folder.badge.plus") {
            folderMenu.create()
          }

          if let removeFromFolder = folderMenu.removeFromFolder {
            Button("Remove from Folder", systemImage: "folder.badge.minus") {
              removeFromFolder()
            }
          }
        }

        // Note(mo): Having archive is confusing
        // Button {
        //   toggleArchive()
        // } label: {
        //   Label(item.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
        // }
      }
    }
    .sheet(isPresented: $showRenameSheet) {
      RenameChatSheet(peer: peerId, initialTitle: item.title)
    }
  }

  @ViewBuilder
  private var titleView: some View {
    let title = Text(item.title)
      .font(rowTitleFont)
      .foregroundStyle(titleColor)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)

    if isTemporary {
      title.italic()
    } else {
      title
    }
  }

  private var titleBlock: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 0) {
        if let parentTitle = visibleParentTitle {
          parentTitleView(parentTitle)
        }

        titleView
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if showsCloseControl {
        closeButton
      } else {
        if size == .compact {
          ComposeActionCompactAccessory(
            peer: peerId,
            reservesSpaceWhenInactive: false
          )
            .id(peerId)
        }

        if let titleAccessory {
          accessoryView(titleAccessory)
        }
      }
    }
  }

  private func parentTitleView(_ title: String) -> some View {
    Text(title)
      .font(Self.parentTitleFont)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var closeButton: some View {
    Button(action: close) {
      SidebarChatCloseIcon()
    }
    .buttonStyle(SidebarCloseButtonStyle(isHovered: isCloseHovered))
    .help("Close")
    .onHover { isCloseHovered = $0 }
  }

  private var showsDisclosureControl: Bool {
    guard disclosureExpanded != nil else { return false }
    return disclosureExpanded == false || hasHoverAppearance
  }

  private var outerHorizontalPadding: CGFloat {
    usesFullWidthCollectionLayout
      ? 8
      : -Theme.sidebarNativeDefaultEdgeInsets + 8
  }

  private var disclosureButton: some View {
    Button {
      onToggleDisclosure?()
    } label: {
      SidebarChatDisclosureIcon(
        isExpanded: disclosureExpanded == true,
        rowHeight: rowHeight,
        animates: !reduceMotion
      )
    }
    .buttonStyle(.plain)
    .offset(x: (Theme.sidebarItemInnerSpacing - 24) / 2)
    .help(disclosureExpanded == true ? "Collapse reply threads" : "Expand reply threads")
    .accessibilityLabel(disclosureExpanded == true ? "Collapse reply threads" : "Expand reply threads")
    .onHover { isDisclosureHovered = $0 }
  }

  private func accessoryView(_ accessory: SidebarChatItemAccessory) -> some View {
    Group {
      switch accessory {
      case .unread:
        unreadBadge
      }
    }
    .frame(minWidth: Self.trailingAccessoryMinWidth, alignment: .center)
    .transition(.scale.combined(with: .opacity))
  }

  private var unreadBadge: some View {
    UnreadBadge(
      unreadCount: item.unread ? item.unreadCount : 0,
      hasUnreadMark: item.unread && item.unreadMark,
      prominent: item.prominentUnreadDot,
      style: unreadBadgeStyle,
      dotSize: Theme.sidebarItemUnreadDotSize
    )
  }

  @ViewBuilder
  private var avatar: some View {
    SidebarChatIdentityIcon(
      identity: item.identity,
      size: iconSize,
      shape: size == .compact ? .none : .circle
    )
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if isActive {
      if colorScheme == .dark { return .white.opacity(0.1) }
      return .black.opacity(0.07)
    }
    if hasHoverAppearance || isDropTargeted {
      if colorScheme == .dark { return .white.opacity(0.06) }
      return .black.opacity(0.05)
    }
    return .clear
  }

  private var isActive: Bool {
    selected || isPressing
  }

  private var titleColor: Color {
    titleDimmed ? Color.secondary : Color.primary
  }

  private var rowTitleFont: Font {
    visibleParentTitle == nil ? Self.titleFont : Self.replyThreadTitleFont
  }

  private var accessibilityTitle: String {
    if let parentTitle = visibleParentTitle {
      return "\(parentTitle), \(item.title)"
    }
    return item.title
  }

  private var accessibilityUnreadValue: Text {
    guard item.unread else { return Text("") }
    if item.unreadCount == 1 {
      return Text("1 unread message")
    }
    if item.unreadCount > 1 {
      return Text("\(item.unreadCount) unread messages")
    }
    if item.unreadMark {
      return Text("Marked unread")
    }
    return Text("Unread")
  }

  private var showsCloseControl: Bool {
    showsCloseButton && hasHoverAppearance
  }

  private var hasHoverAppearance: Bool {
    forceHoverAppearance || isHovered
  }

  private func open() {
    if let onOpen {
      onOpen()
      return
    }

    if let dependencies {
      dependencies.requestOpenChat(peer: peerId)
      return
    }

    nav.open(.chat(peer: peerId))
  }

  private func close() {
    onClose?()
  }

  private func persist() {
    onPersist?()
  }

  private func togglePin() {
    SidebarChatRowActionRunner.togglePin(item)
  }

  private func toggleReadUnread() {
    SidebarChatRowActionRunner.toggleReadUnread(item, dependencies: dependencies)
  }

  private func toggleArchive() {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(
          peerId: peerId,
          archived: !item.archived,
          spaceId: item.spaceId
        )

        if item.archived == false, nav.currentRoute.selectedPeer == peerId {
          await MainActor.run {
            nav.open(.empty)
          }
        }
      } catch {
        Log.shared.error("Failed to update archive state", error: error)
      }
    }
  }
}

@MainActor
enum SidebarChatRowActionRunner {
  static func togglePin(_ item: SidebarViewModel.Item) {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(
          peerId: item.peerId,
          pinned: !item.pinned
        )
      } catch {
        Log.shared.error("Failed to update pin status", error: error)
      }
    }
  }

  static func toggleReadUnread(
    _ item: SidebarViewModel.Item,
    dependencies: AppDependencies?
  ) {
    Task(priority: .userInitiated) {
      do {
        if item.unread {
          UnreadManager.shared.readAll(item.peerId, chatId: item.chatId)
          return
        }

        guard let dependencies else { return }
        try await dependencies.realtimeV2.send(.markAsUnread(peerId: item.peerId))
      } catch {
        Log.shared.error("Failed to update read/unread status", error: error)
      }
    }
  }
}

private enum SidebarChatItemAccessory {
  case unread
}

/// Shared by the SwiftUI and experimental AppKit row renderers so symbol
/// metrics cannot drift between them.
struct SidebarChatCloseIcon: View {
  var body: some View {
    Image(systemName: "xmark")
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(width: 16, height: 16)
  }
}

/// Shared by the SwiftUI and experimental AppKit row renderers. AppKit owns
/// the hit target while SwiftUI continues to own the exact symbol rendering.
struct SidebarChatDisclosureIcon: View {
  let isExpanded: Bool
  let rowHeight: CGFloat
  let animates: Bool

  var body: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 6.5, weight: .bold))
      .foregroundStyle(.secondary)
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .animation(animates ? SidebarDisclosureMotion.animation : nil, value: isExpanded)
      .frame(width: 24, height: rowHeight)
      .contentShape(.interaction, .rect)
  }
}

@MainActor
private struct SidebarComposeActivityPreview: View {
  let peer: Peer
  let preview: String
  let font: Font

  @State private var activityState: ComposeActionActivityState

  init(peer: Peer, preview: String, font: Font) {
    self.peer = peer
    self.preview = preview
    self.font = font
    _activityState = State(initialValue: ComposeActions.shared.activityState(for: peer))
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if let presentation = activityState.presentation {
        HStack(alignment: .center, spacing: 5) {
          ComposeActionActivityIndicator(
            action: presentation.action,
            color: .accentColor
          )

          Text(presentation.text)
            .font(font)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
        }
        .id("activity-\(presentation.action.rawValue)-\(presentation.text)")
        .transition(Self.swapTransition)
      } else {
        Text(preview)
          .font(font)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .id("preview")
          .transition(Self.swapTransition)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 13, alignment: .center)
    .clipped()
    .animation(.easeInOut(duration: 0.18), value: activityState.presentation)
  }

  private static var swapTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.combined(with: .offset(y: 2)),
      removal: .opacity.combined(with: .offset(y: -2))
    )
  }
}

private struct SidebarOpenInteractionModifier: ViewModifier {
  let opensOnMouseDown: Bool
  let isControlHovered: Bool
  @Binding var isPressing: Bool
  let open: () -> Void

  @State private var didOpenDuringPress = false

  func body(content: Content) -> some View {
    if opensOnMouseDown {
      content
        .simultaneousGesture(openOnMouseDownGesture)
    } else {
      content
        .onTapGesture {
          guard isControlHovered == false else { return }
          open()
        }
    }
  }

  private var openOnMouseDownGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        openOnMouseDown()
      }
      .onEnded { _ in
        didOpenDuringPress = false
        isPressing = false
      }
  }

  private func openOnMouseDown() {
    guard didOpenDuringPress == false else { return }
    guard isControlHovered == false else { return }
    didOpenDuringPress = true
    isPressing = true
    open()
  }
}

private struct SidebarCloseButtonStyle: ButtonStyle {
  let isHovered: Bool

  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(.rect(cornerRadius: 5))
      .background(background(isPressed: configuration.isPressed))
  }

  private func background(isPressed: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(backgroundColor(isPressed: isPressed))
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isPressed {
      return colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.13)
    }

    if isHovered {
      return colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08)
    }

    return .clear
  }
}

#Preview {
  SidebarChatItemView(
    item: SidebarViewModel.Item(
      snapshot: ChatListItemSnapshot(
        peer: .thread(id: 9_001),
        chatID: 9_001,
        title: "Preview Chat",
        previewText: "Latest message",
        identity: .thread(ChatListThreadIconDescriptor(
          emoji: "💬",
          title: "Preview Chat",
          isReplyThread: false
        ))
      )
    ),
    selected: true
  )
  .padding()
  .frame(width: 260)
}
