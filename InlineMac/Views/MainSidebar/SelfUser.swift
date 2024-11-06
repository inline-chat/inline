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
            UserAvatar(user: currentUser, size: Theme.sidebarIconSize)
                .padding(.trailing, Theme.sidebarIconSpacing)
                
            Text(currentUser.firstName ?? "You")
                .font(.body)
                .foregroundStyle(.primary)
        }.frame(height: Theme.sidebarIconSize)
    }
    
    func defaultUser() -> User {
        User(email: nil, firstName: "You")
    }
}

#Preview {
    SelfUser()
        .frame(width: 200)
        .previewsEnvironment(.populated)
}
