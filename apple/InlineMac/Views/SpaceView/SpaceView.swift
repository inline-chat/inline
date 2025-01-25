import SwiftUI

public struct SpaceView: View {
  @EnvironmentObject var navigation: NavigationModel

  // Optional
  var inputSpaceId: Int64?

  var spaceId: Int64 {
    if let inputSpaceId {
      inputSpaceId
    } else if let spaceId = navigation.activeSpaceId {
      spaceId
    } else {
      fatalError("Space ID is not provided")
    }
  }

  public init(spaceId: Int64? = nil) {
    inputSpaceId = spaceId
  }

  public var body: some View {
    Text("")
      .navigationTitle("")
  }
}
