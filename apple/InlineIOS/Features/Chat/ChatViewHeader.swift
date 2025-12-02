import SwiftUI

struct ChatViewHeader: View {
  @Binding private var navBarHeight: CGFloat

  init(navBarHeight: Binding<CGFloat>) {
    _navBarHeight = navBarHeight
  }

  let theme = ThemeManager.shared.selected
  var body: some View {
//    LinearGradient(
//      gradient: Gradient(colors: [
//        Color(theme.backgroundColor).opacity(1),
//        Color(theme.backgroundColor).opacity(0.0),
//      ]),
//      startPoint: .top,
//      endPoint: .bottom
//    )
    VariableBlurView(maxBlurRadius: 2)
      /// +28 to enhance the variant blur effect; it needs more space to cover the full navigation bar background
//    .frame(height: 60)  was 38
      .frame(height: navBarHeight + 12) // was 38
       .contentShape(Rectangle())
        .background(
          LinearGradient(
            gradient: Gradient(colors: [
              Color(.systemBackground).opacity(1),
              Color(.systemBackground).opacity(0.0),
            ]),
            startPoint: .top,
            endPoint: .bottom
          )
        )

      // Spacer()
      .ignoresSafeArea(.all)
      .allowsHitTesting(false)
  }
}
