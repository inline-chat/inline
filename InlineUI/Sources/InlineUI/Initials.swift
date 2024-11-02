import SwiftUI

public struct InitialsCircle: View {
    let firstName: String
    let lastName: String?
    let size: CGFloat

    // sdc
    private var initials: String {
        [firstName, lastName].compactMap { $0?.first }.map(String.init)
            .joined()
            .uppercased()
    }

    private var name: String {
        return "\(firstName) \(lastName ?? "")"
    }
    private var color: Color {
        let hash = name.hashValue
        let grayValue = Double(abs(hash) % 40) / 100 + 0.8 // Range from 0.8 to 0.99
        return Color(white: grayValue)
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .overlay(
                    Circle()
                        .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                )

            Text(initials)
                .foregroundColor(.gray)
                .font(.system(size: size * 0.5, weight: .medium))
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    InitialsCircle(firstName: "John", lastName: "Doe", size: 40)
}
