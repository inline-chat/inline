import SwiftUI

struct ChatItem: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LinearGradient(colors: [Color(.systemGray4), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
                .mask {
                    Circle()
                }
                .frame(width: 38)
                .scaledToFit()
                .padding(.top, -4)
            VStack(alignment: .leading) {
                Text("Wanver bugs")
                    .font(.headline)

                Text("the button in the bottom seems small for a thumb, you should make that 3x bigger")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .overlay(alignment: .topTrailing) {
            Badge(count: 123)
        }
    }
}

#Preview {
    ChatItem()
        .padding(.horizontal, 6)
}

struct Badge: View {
    let count: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.blue)
                .padding(.horizontal, 4)
                .scaledToFit()
            Text("\(count)")
                .foregroundColor(.white)
                .font(.caption2.weight(.semibold))
                .monospaced()
        }
        .frame(height: 18)
        .frame(minWidth: 18)
    }
}
