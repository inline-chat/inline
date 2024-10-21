import SwiftUI

struct GrayTextField: View {
    var titleKey: LocalizedStringKey
    var value: Binding<String>
    var prompt: Text?
    
    init(_ titleKey: LocalizedStringKey, text value: Binding<String>) {
        self.titleKey = titleKey
        self.value = value
        self.prompt = nil
    }
    
    init(_ titleKey: LocalizedStringKey, text value: Binding<String>, prompt: Text?) {
        self.titleKey = titleKey
        self.value = value
        self.prompt = prompt
    }
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        TextField(titleKey, text: value, prompt: prompt)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            , weight: .regular))
            .frame(height: 36)
            .focused($isFocused)
            .cornerRadius(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .foregroundStyle(.primary.opacity(isFocused ? 0.1 : 0.06))
                    .animation(.snappy, value: isFocused)
            )
    }
    
//
//            let background: Color = configuration.isPressed ?
//                .primary.opacity(0.1) :
//                .primary.opacity(0.06)
//            let scale: CGFloat = configuration.isPressed ? 0.95 : 1
//
//            configuration.label
//                .font(.system(size: 14, weight: .regular))
//                .frame(height: 36)
//                .padding(.horizontal)
//                .background(background)
//                .foregroundStyle(.primary)
//                .scaleEffect(x: scale, y: scale)
//                .animation(.snappy, value: configuration.isPressed)
//
}

@available(macOS 14, *)
#Preview("Gray Text Field") {
    @Previewable @State var text = ""
    
    GrayTextField("Your Email", text: $text)
        .padding()
}
