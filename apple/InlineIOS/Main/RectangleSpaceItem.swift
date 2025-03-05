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
        HStack {
          SpaceAvatar(space: space, size: 28)
          Text(space.name)
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.primary)
        }
        .frame(height: 48)
        .padding(.horizontal, 14)
        .background {
          RoundedRectangle(cornerRadius: 25)
//            .fill(Color(.systemGray6))
            .strokeBorder(Color(.systemGray5), lineWidth: 1, antialiased: true)
        }
      }
    }
  }
}
