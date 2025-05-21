import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SpacesTab: View {
  @Environment(\.appDatabase) var db
  @Environment(\.keyMonitor) var keyMonitor
  @EnvironmentObject var nav: Nav
  @EnvironmentObject var data: DataManager
  @EnvironmentObject var overlay: OverlayManager
  @EnvironmentStateObject var home: HomeViewModel

  @State private var searchQuery: String = ""

  // MARK: - Initializer

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Views

  var body: some View {
    if let spaceId = nav.selectedSpaceId {
      SpaceMembersView(spaceId: spaceId)
    } else {
      SpaceListView()
      
    }
  }
}

#Preview {
  SpacesTab()
    .previewsEnvironmentForMac(.populated)
}
