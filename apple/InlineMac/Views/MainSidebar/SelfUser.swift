import InlineKit
import InlineUI
import SwiftUI

struct SelfUser: View {
    @EnvironmentObject var rootData: RootData
    
    var currentUser: User {
        rootData.currentUser ?? defaultUser()
    }
    
    var body: some View {
        HStack(spacing: 0) {
            UserAvatar(user: currentUser, size: 24)
                .padding(.trailing, 4)
                
            Text(currentUser.firstName ?? "You")
                .font(.title3)
                .foregroundStyle(.primary)
        }.frame(height: 32)
    }
    
    func defaultUser() -> User {
        User(email: nil, firstName: "You")
    }
}

#Preview {
    SelfUser()
        .previewsEnvironment(.populated)
}
