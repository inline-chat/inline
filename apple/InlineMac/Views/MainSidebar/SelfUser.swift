import SwiftUI
import InlineKit
import InlineUI

struct SelfUser: View {
    @EnvironmentObject var rootData: RootData
    
    var currentUser: User {
        rootData.currentUser ?? defaultUser()
    }
    
    var body: some View {
        HStack {
            UserAvatar(user: currentUser)
                .frame(width: 32, height: 32)
                
            Text(currentUser.firstName ?? "You")
                .font(.body)
                .foregroundStyle(.primary)
        }
    }
    
    func defaultUser() -> User {
        User(email: nil, firstName: "You")
    }
}

#Preview {
    SelfUser()
        .previewsEnvironment(.populated)
}
