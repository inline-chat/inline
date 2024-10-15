import SwiftUI

struct GrayButton<Label>: View
where Label: View
{
    var action: () -> Void
    var label: Label
    
    init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        if #available(macOS 14.0, *) {
            Button(action: action, label: { label })
                .buttonStyle(GrayButtonStyle(isFocused: isFocused))
                .focusEffectDisabled(true)
                .focused($isFocused)
        } else {
            Button(action: action, label: { label })
                .buttonStyle(GrayButtonStyle())
        }
    }
    
    struct GrayButtonStyle: ButtonStyle {
        var isFocused: Bool
        
        init(isFocused: Bool) {
            self.isFocused = isFocused
        }
        
        init() {
            self.isFocused = false
        }
        
        func makeBody(configuration: Configuration) -> some View {
            let background: Color = configuration.isPressed ?
                .primary.opacity(0.1) :
                .primary.opacity(0.06)
            let scale: CGFloat = configuration.isPressed ? 0.95 : 1
            
            configuration.label
                .font(.system(size: 14, weight: .regular))
                .frame(height: 36)
                .padding(.horizontal)
                .background(background)
                .foregroundStyle(.primary)
                .cornerRadius(10)
                .overlay(content: {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(lineWidth: 1.0)
                            .foregroundStyle(.primary.opacity(0.3))
                    }
                })
                .scaleEffect(x: scale, y: scale)
                .animation(.snappy, value: configuration.isPressed)
        }
    }
}

#Preview("Gray Button (Light)") {
    GrayButton(action: { }, label: { Text("Continue") })
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Gray Button (Dark)") {
    GrayButton(action: { }, label: { Text("Continue") })
        .padding()
        .preferredColorScheme(.dark)
}
