import SwiftUI

struct GlassyButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(colorScheme == .dark ? .white : .black)
            .font(.body.weight(.medium))
            .padding(.vertical, 12)
            .frame(width: 250)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(backgroundColor)
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 1)
                    // Shine effect
                    RoundedRectangle(cornerRadius: 16)
                        .fill(shineGradient)
                        .mask(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(shineMaskGradient)
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(overlayGradient, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 5, x: 0, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.05)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.06)
    }

    private var shineGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: colorScheme == .dark ? Color.white.opacity(0.1) : Color.white, location: 0),
                .init(color: .clear, location: 0.5),
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shineMaskGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .clear, location: 0.7),
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var overlayGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                (colorScheme == .dark ? Color.white : Color.black).opacity(0.2),
                .clear,
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }
}

#Preview {
    Button("Text") {}
        .buttonStyle(GlassyButtonStyle())
}

struct PinkButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(colorScheme == .dark ? .white : .black)
            .font(.body.weight(.medium))
            .padding(.vertical, 12)
            .padding(.horizontal, 60)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(backgroundColor)
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 1)
                    // Shine effect
                    RoundedRectangle(cornerRadius: 16)
                        .fill(shineGradient)
                        .mask(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(shineMaskGradient)
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(overlayGradient, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 5, x: 0, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.pink.opacity(0.2) : Color.pink.opacity(0.1)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.pink.opacity(0.3) : Color.pink.opacity(0.06)
    }

    private var shineGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: colorScheme == .dark ? Color.white.opacity(0.1) : Color.white, location: 0),
                .init(color: .clear, location: 0.5),
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shineMaskGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .clear, location: 0.7),
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var overlayGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                (colorScheme == .dark ? Color.white : Color.black).opacity(0.2),
                .clear,
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }
}

#Preview {
    Button("Text") {}
        .buttonStyle(PinkButtonStyle())
}
