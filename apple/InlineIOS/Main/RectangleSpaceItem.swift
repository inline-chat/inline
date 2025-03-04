import Auth
import InlineKit
import InlineUI
import SwiftUI

struct RectangleSpaceItem: View {
  let spaceItem: HomeSpaceItem
  var space: Space { spaceItem.space }

  @EnvironmentObject var nav: Navigation

  var body: some View {
    Button {
      nav.push(.space(id: space.id))
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(Color(.systemGray5), lineWidth: 1, antialiased: true)
          .frame(width: 100, height: 100)
          .overlay {
            VStack {
              SpaceAvatar(space: space, size: 32)
              Text(space.name)
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            }
          }
      }
    }
  }
}
