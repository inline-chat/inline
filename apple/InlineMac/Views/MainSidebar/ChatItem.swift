import InlineKit
import SwiftUI

struct ChatSideItem: View {
  @Binding var selectedRoute: NavigationRoute
  @State private var isHovered = false
  @Environment(\.openWindow) var openWindow
  
  let item: SpaceChatItem
  
  // Gesture state
  @GestureState private var pressState = false
    
  var currentRoute: NavigationRoute {
    .chat(peer: item.peerId)
  }
  
  var title: String {
    item.chat?.title ?? item.user?.fullName ?? "Chat"
  }
  
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "bubble.middle.bottom")
        .frame(width: 16, height: 16)
        
      Text(title)
        .lineLimit(1)
        
      Spacer()
    }
    .padding(.horizontal, Theme.sidebarItemPadding)
    .padding(.vertical, 6)
    .background {
      RoundedRectangle(cornerRadius: 4)
        .fill(backgroundColor)
    }
    .contentShape(Rectangle()) // Makes entire row clickable
    // Double-click handler
    .onTapGesture(count: 2) {
      handleDoubleClick()
    }
    // Single-click handler
    .simultaneousGesture(
      TapGesture(count: 1)
        .modifiers([])
        .onEnded {
          pressed()
        }
    )
    // Command-click handler
    .simultaneousGesture(
      TapGesture(count: 1)
        .modifiers(.command)
        .onEnded {
          handleDoubleClick()
        }
    )

    .onHover { hovering in
      isHovered = hovering
    }
    .onLongPressGesture(perform: {
      print("Long pressed")
      pressed()
    })
  }
  
  private var isSelected: Bool {
    selectedRoute == currentRoute
  }
    
  private var backgroundColor: Color {
    if isSelected {
      return Color.accentColor.opacity(0.2)
    } else if pressState {
      return Color.gray.opacity(0.2)
    } else if isHovered {
      return Color.gray.opacity(0.1)
    } else {
      return Color.clear
    }
  }
    
  private func handleDoubleClick() {
    // Implement double click action
    openWindow(value: item.peerId)
  }

  private func pressed() {
    print("Pressed")
    selectedRoute = currentRoute
  }
}
