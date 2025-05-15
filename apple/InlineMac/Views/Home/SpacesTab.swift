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

  @AppStorage("selectedSpaceId") private var selectedSpaceIdString: String = ""
  @State private var searchQuery: String = ""

  private var selectedSpaceId: Int64? {
    get { Int64(selectedSpaceIdString) }
    nonmutating set { selectedSpaceIdString = newValue?.description ?? "" }
  }

  // MARK: - Initializer

  init() {
    _home = EnvironmentStateObject { env in
      HomeViewModel(db: env.appDatabase)
    }
  }

  // MARK: - Views

  var body: some View {
    if let spaceId = selectedSpaceId {
      SpaceMembersView(spaceId: spaceId, selectedSpaceId: Binding(
        get: { selectedSpaceId },
        set: { selectedSpaceId = $0 }
      ))
    } else {
      SpaceListView(selectedSpaceId: Binding(
        get: { selectedSpaceId },
        set: { selectedSpaceId = $0 }
      ))
    }
  }
}

#Preview {
  SpacesTab()
    .previewsEnvironmentForMac(.populated)
}
