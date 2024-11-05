import InlineKit
import SwiftUI

public struct SpaceAvatar: View {
    let space: Space
    let size: CGFloat

    public init(space: Space, size: CGFloat = 32) {
        self.space = space
        self.size = size
    }

    public var body: some View {
        ZStack {
            InitialsCircle(
                firstName: space.name,
                lastName: nil,
                size: size
            )
        }
    }
}
