import SwiftUI

struct OnboardingWelcome: View {
    @EnvironmentObject var windowViewModel: MainWindowViewModel
    @EnvironmentObject var onboardingViewModel: OnboardingViewModel
    
    var body: some View {
        VStack {
            Image("OnboardingLogoType")
                .renderingMode(.template)
                .foregroundColor(.primary)
                .padding(.top, 30)
            
            Spacer()
            
            Text("Hey There.")
                .font(
                    .custom(Fonts.RedHatDisplay, size: 48, relativeTo: .title)
                ).fontWeight(.bold)
                .padding(.bottom, 1)
            
            Text("Ready for a new way to chat at work?")
                .font(.system(size: 21.0, weight: .medium))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            GrayButton {
                onboardingViewModel.navigate(to: .enterEmail)
            } label: {
                Text("Continue").padding(.horizontal, 60)
            }
            .padding(.bottom, 30)
            
            Footer()
            
        }
        .padding()
        .frame(minWidth: 480, minHeight: 400)
    }
    
    struct Footer: View {
        var body: some View {
            HStack(alignment: .bottom) {
                Text("[inline.chat](https://inline.chat)")
                    .font(.footnote)
                    .tint(Color.secondary)
                
                Spacer()
                
                Text(
                    "By continuing, you acknowledge that you understand and agree to the [Terms & Conditions](https://inline.chat/legal) and [Privacy Policy](https://inline.chat/legal)."
                )
                .font(.footnote)
                .tint(Color.secondary)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                
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
        .environmentObject(OnboardingViewModel())
        .frame(width: 900, height: 600)
}