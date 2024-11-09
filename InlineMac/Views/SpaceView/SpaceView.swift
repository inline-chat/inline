import SwiftUI

public struct SpaceView: View {
  @EnvironmentObject var navigation: NavigationModel

  // Optional
  var inputSpaceId: Int64?

  var spaceId: Int64 {
    if let inputSpaceId = inputSpaceId {
      return inputSpaceId
    } else if let spaceId = navigation.activeSpaceId {
      return spaceId
    } else {
      fatalError("Space ID is not provided")
    }
  }

  public init(spaceId: Int64? = nil) {
    self.inputSpaceId = spaceId
  }

  public var body: some View {
    Text("Space View \(spaceId)")
      .navigationTitle("Space")
  }
}
