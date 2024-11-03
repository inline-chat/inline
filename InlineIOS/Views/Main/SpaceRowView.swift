import InlineKit
import InlineUI
import SwiftUI

struct SpaceRowView: View {
    let space: Space

    var body: some View {
        HStack {
            InitialsCircle(firstName: space.name, lastName: nil, size: 25)
                .padding(.trailing, 4)
            Text(space.name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#Preview("SpaceRowView") {
    SpaceRowView(space: Space(id: 1, name: "Engineering", date: Date()))
        .padding()
}
