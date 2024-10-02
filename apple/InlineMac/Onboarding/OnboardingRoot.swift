import Cocoa
import SwiftUI

struct OnboardingRoot: View {
//    @EnvironmentObject var nav: Nav
//    @EnvironmentObject var window: WindowActions

    var body: some View {
        VStack {
            Text("Welcome to Inline.").font(.largeTitle)
            Button {
//                nav.navigate(to: .spaceView)
            } label: {
                Text("Continue")
            }
        }.padding()
            .onAppear {
//                window.setWindowStyle?(.onboarding)
            }
    }
}

#Preview {
    OnboardingRoot()
}

class OnboardingViewController: NSViewController {
    private var hostingController: NSHostingController<AnyView>!
    
    override func loadView() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view = contentView
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Create the SwiftUI view
        let onboardingRoot = OnboardingRoot()
        
        // Wrap it in AnyView to erase the specific type
        let anyView = AnyView(onboardingRoot)
        
        // Create a hosting controller with the SwiftUI view
        hostingController = NSHostingController(rootView: anyView)
        
        // Add the hosting controller as a child view controller
        addChild(hostingController)
        
        // Add the hosting view to the view hierarchy
        view.addSubview(hostingController.view)
        
        // Set up constraints
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
