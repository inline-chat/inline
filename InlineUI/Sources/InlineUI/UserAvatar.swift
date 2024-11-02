import SwiftUI
import InlineKit

public struct UserAvatar: View {
    let user: User
    let size: CGFloat
    
    public init(user: User, size: CGFloat = 32) {
        self.user = user
        self.size = size
    }
    
    
    public var body: some View {
        ZStack {
            InitialsCircle(
                firstName: user.firstName ?? user.email?.components(separatedBy: "@").first ?? "User",
                lastName: user.lastName,
                size: size
            )
        }
    }
}

