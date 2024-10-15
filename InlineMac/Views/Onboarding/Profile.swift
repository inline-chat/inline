import InlineKit
import SwiftUI

struct OnboardingProfile: View {
    @EnvironmentObject var onboardingViewModel: OnboardingViewModel
    
    var body: some View {
        VStack {
            Image(systemName: "person.and.background.dotted")
                .resizable(resizingMode: .tile)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundColor(.primary)
                .padding(.bottom, 4)
            
            Text("Set up your profile")
                .font(.system(size: 21.0, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

#Preview {
    OnboardingProfile()
        .environmentObject(OnboardingViewModel())
        .frame(width: 900, height: 600)
}
