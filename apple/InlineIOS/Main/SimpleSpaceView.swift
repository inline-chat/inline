import InlineKit
import InlineUI
import SwiftUI

struct SimpleSpaceItemProps {
  let space: Space
  let hasUnread: Bool
}

struct SimpleSpaceItemView: View {
  let props: SimpleSpaceItemProps

  var space: Space {
    props.space
  }

  var hasUnread: Bool {
    props.hasUnread
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Circle()
        .fill(hasUnread ? Color.accentColor : .clear)
        .frame(width: 6, height: 6)
        .animation(.easeInOut(duration: 0.3), value: hasUnread)

      SpaceAvatar(space: space, size: 36)
      
      Text(space.name)
        .font(.customTitle())
        .foregroundColor(.primary)

      Spacer()
    }
    .padding(.vertical, 8)
  }
}
