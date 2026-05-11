import InlineKit
import SwiftUI

struct ProfileRouteView: View {
  let userId: Int64

  var body: some View {
    if let userInfo = ObjectCache.shared.getUser(id: userId) {
      UserProfile(userInfo: userInfo)
    } else {
      RoutePlaceholderView(
        title: "Profile Unavailable",
        systemImage: "person.crop.circle.badge.exclamationmark"
      )
    }
  }
}
