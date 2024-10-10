import SwiftUI

struct AnimatedLabel: View {
    @Binding var animate: Bool
    var text: String
    var body: some View {
        Text(text)
            .font(animate ? .title2 : .largeTitle)
            .fontWeight(.medium)
            .foregroundColor(animate ? .secondary : .primary)
    }
}

#Preview {
    AnimatedLabel(animate: .constant(true), text: "Enter your email")
}

#Preview {
    AnimatedLabel(animate: .constant(false), text: "Enter your email")
}
