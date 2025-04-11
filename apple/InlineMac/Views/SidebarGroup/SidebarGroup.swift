import AppKit
import Logger
import SwiftUI

struct SidebarGroup<Content: View>: View {
  @Environment(\.colorScheme) var colorScheme

  let systemImage: String
  let title: String
  let content: Content
  @Binding var isExpanded: Bool
  let action: (() -> Void)?

  @State var isHovering: Bool = false

  init(
    systemImage: String,
    title: String,
    isExpanded: Binding<Bool>,
    @ViewBuilder content: () -> Content,
    action: (() -> Void)? = nil
  ) {
    self.content = content()
    self.systemImage = systemImage
    self.title = title
    _isExpanded = isExpanded
    self.action = action
  }

  var body: some View {
    VStack(spacing: 0) {
      buttons

      contentView
    }
    .padding(.bottom, 8)
    .animation(.smoothSnappy, value: isExpanded)
    .animation(.easeOut.speed(2), value: isHovering)
    .onHover { hovered in
      isHovering = hovered
    }
  }

  @ViewBuilder var buttons: some View {
    HStack(spacing: 0) {
      Button(action: {
        isExpanded.toggle()
      }) {
        HStack(spacing: 0) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.snappy, value: isExpanded)
            .foregroundColor(Color(Theme.colorIconGray))
            .opacity(isHovering || !isExpanded ? 1 : 0)
            .frame(width: Theme.sidebarItemInnerSpacing, height: Theme.sidebarItemInnerSpacing, alignment: .leading)
            .fixedSize()

          Image(systemName: systemImage)
            .foregroundColor(Color(Theme.colorIconGray))
            .font(.system(size: 15))
            .frame(width: Theme.sidebarIconSize, height: Theme.sidebarIconSize, alignment: .leading)
            .fixedSize()
        }
        .padding(.horizontal, 0)
        .contentShape(Rectangle())
      }
      .buttonStyle(PlainButtonStyle())
      .padding(.horizontal, 0)

      Button(action: { action?() }) {
        Text(title)
          .font(Theme.sidebarItemFont)
          .foregroundStyle(Color(Theme.colorTitleTextGray))
          .contentShape(Rectangle())
      }

      .buttonStyle(PlainButtonStyle())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 0)
      .padding(.leading, Theme.sidebarIconSpacing)
    }
    .frame(height: Theme.sidebarItemHeight)
    .padding(.leading, Theme.sidebarItemOuterSpacing)
    .zIndex(2.0)
  }

  @State private var contentHeight: CGFloat = 0

  @ViewBuilder var contentView: some View {
    ZStack {
      if isExpanded {
        // ZStack {
        LazyVStack(spacing: 0) {
          content
        }
        //        GeometryReader { geometry in
        //          Color.clear
        //            .preference(key: ContentHeightPreferenceKey.self, value: geometry.size.height)
        //        }
        //      }
        //
        //      .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
        //        if height != contentHeight {
        //          Log.shared.debug("SidebarGroup content height changed: \(height)")
        //          contentHeight = height
        //        }
        //      }
        //      .offset(y: isExpanded ? 0 : -contentHeight + 20)
        //      .opacity(isExpanded ? 1 : 0)
        // .scaleEffect(isExpanded ? 1.0 : 0.9)

        .scaleEffect(1.0)
        .transition(
          .asymmetric(
            insertion: .push(from: .top),
            removal: .push(from: .bottom)
          ).combined(with: .opacity)
        )
      }
    }
    .frame(
      minWidth: 0,
      maxWidth: .infinity,
      maxHeight: isExpanded ? .infinity : 0,
    )
    .padding(.horizontal, Theme.sidebarContentSideSpacing)
    .clipped()
    // push it behind during transition
    .zIndex(1.0)
  }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}
