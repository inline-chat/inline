import InlineKit
import InlineUI
import SwiftUI

struct SpaceRowView: View {
  let spaceItem: SpaceItem

  var body: some View {
    HStack(alignment: .top) {
      SpaceAvatar(space: spaceItem.space, size: 36)
        .padding(.trailing, 6)

      VStack(alignment: .leading) {
        Text(spaceItem.space.name)
          .fontWeight(.medium)
          .foregroundColor(.primary)

        Text("\(spaceItem.members.count) members")
          .font(.callout)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
      }
    }
    .frame(height: 48)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
