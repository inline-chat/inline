import InlineKit
import InlineUI
import SwiftUI

struct SpaceRowView: View {
  let spaceItem: SpaceItem

  var body: some View {
    HStack(alignment: .top) {
      SpaceAvatar(space: spaceItem.space, size: 42)
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
      }
    }
    .padding(.top, 8)
    .frame(height: 66)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
