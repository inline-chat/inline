import GRDB
import InlineKit
import InlineUI
import SwiftUI

struct MemberView: View {
  var userId: Int64
  @EnvironmentStateObject var userDataViewModel: UserDataViewModel

  init(userId: Int64) {
    self.userId = userId
    _userDataViewModel = EnvironmentStateObject { env in
      UserDataViewModel(db: env.appDatabase, userId: userId)
    }
  }

  var body: some View {
    HStack {
      if let user = userDataViewModel.user {
        UserAvatar(user: user, size: 25)
          .padding(.trailing, 4)
        Text(user.firstName ?? "")
      }
    }
  }
}

#Preview {
  MemberView(userId: Int64.random(in: 1 ... 500))
}
