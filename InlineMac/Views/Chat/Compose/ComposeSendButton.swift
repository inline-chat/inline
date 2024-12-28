import AppKit
import InlineKit
import SwiftUI

class ComposeSendButton: NSView {
  var state = ComposeSendButtonState()
    
  var onSend: (() -> Void)?
  
  // MARK: - Views
  
  private lazy var view: NSHostingView<ComposeSendButtonSwiftUI> = {
    let sendButton = ComposeSendButtonSwiftUI(state: state) { [weak self] in
      self?.onSend?()
    }
    let hostingView = NSHostingView(rootView: sendButton)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(.required, for: .horizontal)
    hostingView.setContentHuggingPriority(.required, for: .vertical)
    return hostingView
  }()
  
  // MARK: - Initialization
  
  init(frame: NSRect = .zero, onSend: (() -> Void)? = nil) {
    self.onSend = onSend
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
      widthAnchor.constraint(equalToConstant: Theme.messageAvatarSize),
      heightAnchor.constraint(equalToConstant: Theme.messageAvatarSize)
    ])
  }
  
  // MARK: - Actions

  func updateCanSend(_ canSend: Bool) {
    DispatchQueue.main.async {
      self.state.canSend = canSend
    }
  }
}

class ComposeSendButtonState: ObservableObject {
  @Published var canSend = false
}
