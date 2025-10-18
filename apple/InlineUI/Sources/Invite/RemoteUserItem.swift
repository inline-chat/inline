import InlineKit
import InlineUI
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public struct RemoteUserItem: View {
  public var user: ApiUser
  public var highlighted: Bool = false
  public var action: (() -> Void)?
  
  #if os(macOS)
  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool
  #endif
  
  public init(user: ApiUser, highlighted: Bool = false, action: (() -> Void)? = nil) {
    self.user = user
    self.highlighted = highlighted
    self.action = action
  }
  
  public var body: some View {
    #if os(macOS)
    macOSView
    #else
    iOSView
    #endif
  }
  
  #if os(macOS)
  private var macOSView: some View {
    let view = Button {
      if let action {
        action()
      }
    } label: {
      HStack(spacing: 0) {
        UserAvatar(apiUser: user)
          .padding(.trailing, 8)

        VStack(alignment: .leading, spacing: 0) {
          Text(user.firstName ?? user.username ?? "")
            .lineLimit(1)

          if let username = user.username {
            Text("@\(username)")
              .lineLimit(1)
              .foregroundStyle(.secondary)
              .font(.caption)
          }
        }
        Spacer()
      }
      .frame(height: 32)
      .onHover { isHovered = $0 }
      .contentShape(.interaction, .rect(cornerRadius: 6))
      .padding(.horizontal, 8)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(backgroundColor)
      }
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .padding(.vertical, 2)
    .padding(.bottom, 1)
    .padding(.horizontal, 4)

    if #available(macOS 14.0, *) {
      return view.focusEffectDisabled()
    } else {
      return view
    }
  }
  
  private var backgroundColor: Color {
    #if os(macOS)
    if highlighted {
      .primary.opacity(0.1)
    } else if isFocused {
      .primary.opacity(0.1)
    } else if isHovered {
      .primary.opacity(0.05)
    } else {
      .clear
    }
    #else
    .clear
    #endif
  }
  #endif
  
  #if os(iOS)
  private var iOSView: some View {
    Button(action: {
      action?()
    }) {
      HStack(alignment: .center, spacing: 9) {
        UserAvatar(apiUser: user, size: 34)

        VStack(alignment: .leading, spacing: 0) {
          Text(user.firstName ?? user.username ?? "")
            .font(.body)
            .foregroundColor(.primary)
            .lineLimit(1)

          if let username = user.username {
            Text("@\(username)")
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()
      }
    }
    .buttonStyle(.plain)
  }
  #endif
}

#Preview {
  VStack(spacing: 0) {
    RemoteUserItem(user: ApiUser.preview)
    RemoteUserItem(
      user: ApiUser.preview,
      highlighted: true,
      action: {}
    )
  }
  .frame(width: 200)
  .previewsEnvironment(.populated)
}
