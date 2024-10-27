import SwiftUI

struct InitialsCircle: View {
  let name: String

  private var initial: String {
    String(name.prefix(1).uppercased())
  }

  private var color: Color {
    let hash = name.hashValue
    return Color(hue: Double(abs(hash) % 256) / 256, saturation: 0.7, brightness: 0.9)
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(color)

      Text(initial)
        .foregroundColor(.white)
        .font(.system(size: 1000))
        .minimumScaleFactor(0.01)
        .padding(4)
    }
    .frame(width: 40, height: 40)
  }
}

#Preview {
  InitialsCircle(name: "John Doe")
}
