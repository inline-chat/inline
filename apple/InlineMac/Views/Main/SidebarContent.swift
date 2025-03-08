import Combine
import GRDB
import InlineKit
import InlineUI
import Logger
import RealtimeAPI
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
    .onChange(of: nav.currentSpaceId) { newValue in
      if let newSpaceId = newValue {
        // Going to a space
        withAnimation(.smoothSnappy) {
          animatingSpaceId = newSpaceId
        }
      } else {
        // Going back to home
        withAnimation(.smoothSnappy) {
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
