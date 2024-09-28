import SwiftUI

struct OnboardingRoot: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var app: AppActions

    var body: some View {
        VStack {
            Text("Welcome to Inline.").font(.largeTitle)
            Button {
                nav.navigate(to: .spaceView)
            } label: {
                Text("Continue")
            }

        }.padding()
            .onAppear {
                app.clearToolbar()
            }
    }
}

#Preview {
    OnboardingRoot()
}
