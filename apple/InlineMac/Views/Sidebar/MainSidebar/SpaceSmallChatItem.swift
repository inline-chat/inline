import InlineKit
import InlineUI
import SwiftUI

struct SpaceSmallChatItem: View {
  // MARK: - Props

  var chat: Chat
  var selected: Bool = false
  var onPress: (() -> Void)?

  // MARK: - Constants

  static var iconSize: CGFloat = 32
  static var titleFont: Font = .system(size: 13.0).weight(.regular)
  static var height: CGFloat = 38
  static var verticalPadding: CGFloat = (Self.height - Self.iconSize) / 2
  static var iconSpacing: CGFloat = 8
  static var radius: CGFloat = 10
  static var gutterWidth: CGFloat = Theme.sidebarItemInnerSpacing

  // MARK: - State

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered: Bool = false

  // MARK: - Initializer

  init(
    chat: Chat,
    selected: Bool = false,
    onPress: (() -> Void)? = nil
  ) {
    self.chat = chat
    self.selected = selected
    self.onPress = onPress
  }

  // MARK: - Views

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      gutter
      content
    }
    .padding(.vertical, Self.verticalPadding)
    .frame(height: Self.height)
    .background(background)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 1)
    .padding(
      .horizontal,
      -Theme.sidebarNativeDefaultEdgeInsets +
        Theme.sidebarItemOuterSpacing
    )
    .onHover { hovering in
      isHovered = hovering
    }
    .onTapGesture {
      onPress?()
    }
  }

  @ViewBuilder
  var content: some View {
    HStack(spacing: 0) {
      ChatIcon(peer: .chat(chat), size: Self.iconSize)
        .padding(.trailing, Self.iconSpacing)

      Text(chat.title ?? "Untitled Thread")
        .lineLimit(1)
        .font(Self.titleFont)
        .foregroundColor(.primary)

      Spacer()
    }
  }

  @ViewBuilder
  var gutter: some View {
    HStack(spacing: 0) {
      // Reserved for future indicators
    }
    .frame(width: Self.gutterWidth, height: Self.iconSize)
  }

  @ViewBuilder
  var background: some View {
    RoundedRectangle(cornerRadius: Self.radius)
      .fill(
        selected ? selectedBackgroundColor :
          isHovered ? Color.gray.opacity(0.1) :
          Color.clear
      )
      .shadow(
        color:
        selected ? Color.black.opacity(0.1) :
          Color.clear,
        radius: 1,
        x: 0,
        y: 1
      )
      .animation(.fastFeedback, value: isHovered)
  }

  // MARK: - Computed Properties

  var selectedBackgroundColor: Color {
    // Gray style
    colorScheme == .dark ? .white.opacity(0.1) : .gray.opacity(0.1)
  }
}

#Preview {
  SpaceSmallChatItem(
    chat: .preview,
    selected: false,
    onPress: {}
  )
  .listStyle(.sidebar)
  .previewsEnvironmentForMac(.populated)
  .frame(width: 300, height: 800)
}
