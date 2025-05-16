import InlineKit
import InlineUI
import SwiftUI

struct SpacesView: View {
  @AppStorage("selectedSpaceId") private var selectedSpaceIdString: String = ""
  @EnvironmentObject private var home: HomeViewModel

  private var selectedSpaceId: Int64? {
    get { Int64(selectedSpaceIdString) }
    nonmutating set { selectedSpaceIdString = newValue?.description ?? "" }
  }

  var body: some View {
    NavigationStack {
      List(home.spaces.sorted(by: { s1, s2 in
        s1.space.name < s2.space.name
      })) { space in
        NavigationLink {
          NewSpaceView(spaceId: space.space.id)
        } label: {
          HStack {
            SpaceAvatar(space: space.space, size: 34)
            Text(space.space.nameWithoutEmoji)
          }
        }
        .buttonStyle(.plain)
        .background(selectedSpaceId == space.space.id ? Color(.systemGray6) : .clear)
      }
    }
    .listStyle(.plain)
  }
}
