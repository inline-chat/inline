import Combine
import GRDB
import InlineKit
import InlineUI
import Logger

import SwiftUI

struct SidebarContent: View {
  @EnvironmentObject var window: MainWindowViewModel
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var rootData: RootData
  @EnvironmentObject var dataManager: DataManager

  @State private var animatingSpaceId: Int64? = nil

  init() {}

  var body: some View {
    ZStack {
      if animatingSpaceId == nil {
        HomeSidebar()
          .transition(.move(edge: .leading))
          .id("home")
          .zIndex(1)
      } else if let spaceId = animatingSpaceId {
        SpaceSidebar(spaceId: spaceId)
          .transition(.move(edge: .trailing))
          .id("space-\(spaceId)")
          .zIndex(1)
      }
    }
    .background(
      Color(nsColor: .controlBackgroundColor)
        .opacity(0.3)
        .ignoresSafeArea() // For full coverage
    )

    .onChange(of: nav.currentSpaceId) { newValue in
      if let newSpaceId = newValue {
        // Going to a space
        withAnimation(.smoothSnappier) {
          animatingSpaceId = newSpaceId
        }
      } else {
        // Going back to home
        withAnimation(.smoothSnappier) {
          animatingSpaceId = nil
        }
      }
    }
    .onAppear {
      // Initialize without animation
      animatingSpaceId = nav.currentSpaceId
    }
  }
}

#Preview {
  SidebarContent()
    .previewsEnvironmentForMac(.empty)
}
