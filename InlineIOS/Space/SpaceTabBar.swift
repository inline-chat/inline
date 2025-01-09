import SwiftUI

enum SpaceTab {
  case all
  case chats
  case members

  var title: String {
    switch self {
    case .all: return "All"
    case .chats: return "Chats"
    case .members: return "Members"
    }
  }
}

struct SpaceTabBar: View {
  @Binding var selectedTab: SpaceTab
  let tabs: [SpaceTab] = [.all, .chats, .members]

  @Namespace private var animation

  var body: some View {
    HStack(spacing: 22) {
      ForEach(tabs, id: \.self) { tab in
        Button {
          withAnimation(.easeInOut(duration: 0.2)) {
            selectedTab = tab
          }
        } label: {
          VStack(spacing: 4) {
            Text(tab.title)
              .foregroundColor(selectedTab == tab ? .primary : .secondary)

            ZStack {
              if selectedTab == tab {
                TopRoundedRectangle()
                  .frame(height: 4)
                  .foregroundColor(.blue)
                  .matchedGeometryEffect(id: "tab", in: animation)
              } else {
                Color.clear.frame(height: 4)
              }
            }
          }
        }
      }
    }
    .fixedSize()
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .animation(.easeInOut(duration: 0.2), value: selectedTab)
  }
}

struct TopRoundedRectangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let radius: CGFloat = 2

    // Top left corner
    path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false)

    // Top right corner
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                radius: radius,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false)

    // Bottom right corner (no rounding)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

    // Bottom left corner (no rounding)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

    path.closeSubpath()
    return path
  }
}
