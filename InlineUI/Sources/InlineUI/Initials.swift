import SwiftUI

public struct InitialsCircle: View {
    let firstName: String
    let lastName: String?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public var initials: String {
        [firstName, lastName].compactMap { $0?.first }.map(String.init)
            .joined()
            .uppercased()
    }

    public var name: String {
        return "\(firstName) \(lastName ?? "")"
    }

    public var color: Color {
        let hash = name.hashValue
        let baseValue = Double(abs(hash) % 40) / 100 // Range from 0 to 0.4

        // For dark mode, we want darker colors (0.15-0.35)
        // For light mode, we want slightly darker colors (0.8-0.99)
        return colorScheme == .dark
            ? Color(white: baseValue + 0.15) // Range from 0.15 to 0.35
            : Color(white: baseValue + 0.8) // Range from 0.8 to 0.99
    }

    public init(firstName: String, lastName: String?, size: CGFloat = 32) {
        self.firstName = firstName
        self.lastName = lastName
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .overlay(
                    Circle()
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(0.1)
                                : Color.gray.opacity(0.2),
                            lineWidth: 1
                        )
                )

            Text(initials)
                .foregroundColor(colorScheme == .dark ? .white : .gray)
                .font(.system(size: size * 0.5, weight: .medium))
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    InitialsCircle(firstName: "John", lastName: "Doe", size: 40)
}
