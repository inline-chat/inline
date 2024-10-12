import SwiftUI

struct Onboarding: View {
    @EnvironmentObject var windowViewModel: MainWindowViewModel
    
    var body: some View {
        VStack {
            Image("OnboardingLogoType")
                .renderingMode(.template)
                .foregroundColor(.primary)
                .padding(.top, 50)
            
            Spacer()
            
            Text("Hey There.")
                .font(
                    .custom(Fonts.RedHatDisplay, size: 48, relativeTo: .title)
                ).fontWeight(.bold)
                
            Text("Ready for a new way to chat at work?")
                .font(.title)
                .fontWeight(.regular)
            
            Spacer()
            Button {
                windowViewModel.navigate(.main)
            } label: {
                Text("Continue")
            }.buttonStyle(GrayButtonStyle())
            
            Footer()
                .padding(.top, 12)
        }.padding()
    }
    
    
    struct GrayButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            let background: Color = configuration.isPressed ?
                .primary.opacity(0.1) :
                .primary.opacity(0.06)
            let scale: CGFloat = configuration.isPressed ? 0.95 : 1
            
            configuration.label
                .font(.body)
                .fontWeight(.medium)
                .frame(height: 34)
                .padding(.horizontal)
                .background(background)
                .foregroundStyle(.primary)
                .cornerRadius(10)
                .scaleEffect(x: scale, y: scale)
                .animation(.snappy, value: configuration.isPressed)
           
        }
    }
    
    
    struct Footer: View {
        var body: some View {
            HStack(alignment: .bottom) {
                Text("[inline.chat](https://inline.chat)")
                    .tint(Color.secondary)
                
                Spacer()
                
                Text(
                    "By continuing, you acknowledge that you understand and agree to the [Terms & Conditions](https://inline.chat/legal) and [Privacy Policy](https://inline.chat/legal)."
                )
                .tint(Color.secondary)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                
                Spacer()
                
                Button(
                    "English",
                    systemImage: "globe",
                    action: {
                        // ..
                    }
                )
                .buttonStyle(.borderless)
            }
        }
    }
}

#Preview {
    Onboarding()
        .environmentObject(MainWindowViewModel())
        .frame(width: 900, height: 600)
}
