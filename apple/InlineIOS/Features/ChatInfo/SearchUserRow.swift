import InlineKit
import InlineUI
import SwiftUI

struct SearchUserRow: View {
  let userInfo: UserInfo
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 9) {
        UserAvatar(userInfo: userInfo, size: 32)
        Text((userInfo.user.firstName ?? "") + " " + (userInfo.user.lastName ?? ""))
          .fontWeight(.medium)
            
      }
    }
  }
}
