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

  init() {}

  var body: some View {
    sidebar
  }

  @ViewBuilder
  var sidebar: some View {
    if let spaceId = nav.currentSpaceId {
      SpaceSidebar(spaceId: spaceId)
    } else {
      HomeSidebar()
    }
  }
}

#Preview {
  SidebarContent()
    .previewsEnvironmentForMac(.empty)
}
