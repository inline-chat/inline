import InlineKit
import InlineUI
import SwiftUI

struct SpaceRowView: View {
  let spaceItem: SpaceItem

  var body: some View {
    HStack {
      InitialsCircle(firstName: spaceItem.space.name, lastName: nil, size: 36)
        .padding(.trailing, 6)
        .padding(.top, -6)
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
    .frame(height: 48)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
