import SwiftUI

struct Onboarding: View {
    @EnvironmentObject var windowViewModel: MainWindowViewModel
    
    var body: some View {
        VStack {
            Text("Welcome to Inline.").font(.largeTitle)
            Button {
                windowViewModel.navigate(.main)
            } label: {
                Text("Continue")
            }
        }.padding()
    }
}

#Preview {
    Onboarding()
        .environmentObject(MainWindowViewModel())
}
