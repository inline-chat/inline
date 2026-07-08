import SwiftUI
import UIKit

class ShareViewController: UIViewController {
  private let state = ShareState()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let shareView = ShareView()
      .environmentObject(state)
      .environment(\.extensionContext, extensionContext)

    let hostingController = UIHostingController(rootView: shareView)
    hostingController.view.backgroundColor = .clear
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    Task { await state.prepareConnection() }
    loadSharedContent()
  }

  private func loadSharedContent() {
    guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
      return
    }

    state.loadSharedContent(from: extensionItems)
  }
}
