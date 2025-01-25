
import SwiftUI

struct ComposeMenuButtonSwiftUI: View {
  @State private var isHovering = false
  @State var attachmentOverlayOpen = false

  private let size: CGFloat = Theme.messageAvatarSize
  private let backgroundColor: Color = .accentColor
  private let hoveredBackgroundColor: Color = .accentColor.opacity(0.8)

  var body: some View {
    Button {
      // open picker
      withAnimation(.smoothSnappy) {
        attachmentOverlayOpen.toggle()
      }
    } label: {
      Image(systemName: "plus")
        .resizable()
        .scaledToFit()
        .foregroundStyle(.tertiary)
        .fontWeight(.bold)
    }
    .buttonStyle(
      CircleButtonStyle(
        size: Theme.messageAvatarSize,
        backgroundColor: .clear,
        hoveredBackgroundColor: .gray.opacity(0.1)
      )
    )
    .background(alignment: .bottomLeading) {
      if attachmentOverlayOpen {
        VStack {
          Text("Soon you can attach photos and files from here!").padding()
        }.frame(width: 140, height: 140)
          .background(.regularMaterial)
          .zIndex(2)
          .cornerRadius(12)
          .offset(x: 10, y: -50)
          .transition(.scale(scale: 0, anchor: .bottomLeading).combined(with: .opacity))
      }
    }
  }
}

//
// #Preview {
//  ComposeSendButtonSwiftUI(state: ComposeSendButtonState(canSend: true), action: {})
//    .frame(width: 100, height: 100)
// }
