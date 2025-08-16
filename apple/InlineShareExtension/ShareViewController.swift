import Logger
import SwiftUI
import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
  private let log = Log.scoped("ShareViewController")
  private let state = ShareState()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.2)

    let shareView = ShareView()
      .environmentObject(state)
      .environment(\.extensionContext, extensionContext)
    
    let hostingController = UIHostingController(rootView: shareView)
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)
    
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    loadSharedContent()
  }

  private func loadSharedContent() {
    guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
      return
    }

    state.loadSharedContent(from: extensionItems)
  }
}
