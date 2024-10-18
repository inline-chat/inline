import GRDB
import InlineKit
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
        if let user = userDataViewModel.user {
            Text(user.firstName)
        }
    }
}

#Preview {
    MemberView(userId: Int64.random(in: 1 ... 500))
}
