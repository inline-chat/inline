
import AppKit
import InlineKit
import SwiftUI

class ComposeMenuButton: NSView {
  // MARK: - Views

  private lazy var view: NSHostingView<ComposeMenuButtonSwiftUI> = {
    let button = ComposeMenuButtonSwiftUI()
    let hostingView = NSHostingView(rootView: button)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(.required, for: .horizontal)
    hostingView.setContentHuggingPriority(.required, for: .vertical)
    return hostingView
  }()

  // MARK: - Initialization

  override init(frame: NSRect = .zero) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupView() {
    // Ensure this view doesn't translate autoresizing masks
    translatesAutoresizingMaskIntoConstraints = false

    // Add the hosting view
    addSubview(view)

    // Set up constraints
    NSLayoutConstraint.activate([
      // Pin hosting view to all edges
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
      view.topAnchor.constraint(equalTo: topAnchor),
      view.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Set fixed size for the button container
      widthAnchor.constraint(equalToConstant: Theme.composeButtonSize),
      heightAnchor.constraint(equalToConstant: Theme.composeButtonSize),
    ])
  }

  // MARK: - Actions
}
