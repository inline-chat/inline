import AppKit
import Combine
import InlineKit
import Observation

// This is a sample view that we copy paste when we need a new view.
class SampleView: NSViewController {
  private static let height: CGFloat = 32

  private let dependencies: AppDependencies
  private var nav2: Nav2? { dependencies.nav2 }

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Header
  private lazy var stackView: NSStackView = {
    let view = NSStackView()
    view.orientation = .horizontal
    view.alignment = .centerY
    view.distribution = .fill
    view.spacing = 6
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var textView: NSTextField = {
    let view = NSTextField(labelWithString: "")
    view.font = .systemFont(ofSize: 13, weight: .semibold)
    view.textColor = .secondaryLabelColor
    view.lineBreakMode = .byTruncatingTail
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
  }

  private func setupViews() {
    view.addSubview(stackView)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      stackView.bottomAnchor.constraint(equalTo: textView.topAnchor, constant: 6),
    ])
  }

  override func viewWillLayout() {
    super.viewWillLayout()

    // Update properties and get automatic observation tracking!
    textView.stringValue = "Home"
  }
}
