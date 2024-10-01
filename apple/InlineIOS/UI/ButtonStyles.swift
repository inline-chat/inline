import SwiftUI

struct SimpleWhiteButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.black)
            .font(.body)
            .fontWeight(.semibold)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.96))
            .cornerRadius(12)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct SimpleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.body)
            .fontWeight(.medium)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(.blue)
            .cornerRadius(12)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

#Preview {
    Button("Text") {}
        .buttonStyle(SimpleButtonStyle())
}
