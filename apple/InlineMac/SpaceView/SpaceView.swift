import Cocoa
import SwiftUI

struct SpaceView: View {
    @EnvironmentObject var app: AppActions

    var body: some View {
        CustomSplitView()
            .edgesIgnoringSafeArea(.all)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                app.setUpToolbar()
            }
    }
}

class MainSplitViewController: NSSplitViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure the split view
        splitView.dividerStyle = .thin
        splitView.isVertical = true

        // Create and configure the sidebar view controller
        let sidebarViewController = SidebarViewController()
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        //        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(251)

        sidebarItem.preferredThicknessFraction = 0.2  // 20% of the window width

        // Create and configure the content view controller
        let contentViewController = ContentViewController()
        let contentItem = NSSplitViewItem(viewController: contentViewController)

        // Add the split view items
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
    }
}

class SidebarViewController: NSViewController {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

class ContentViewController: NSViewController {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
    }
}

// Placeholder SwiftUI views
struct FirstView: View {
    var body: some View {
        Text("First View")
            .padding()
    }
}

struct SecondView: View {
    var body: some View {
        Text("Second View")
            .padding()
    }
}

struct CustomSplitView: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> MainSplitViewController {
        return MainSplitViewController()
    }

    func updateNSViewController(
        _ nsViewController: MainSplitViewController, context: Context
    ) {
        // Update code if necessary
    }
}
