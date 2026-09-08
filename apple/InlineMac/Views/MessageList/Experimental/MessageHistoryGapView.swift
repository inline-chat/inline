import AppKit

/// A truthful boundary between cached fragments, with an explicit retry action.
final class MessageHistoryGapView: NSView {
  static let height: CGFloat = 36
  private let button = NSButton(title: "Load missing messages", target: nil, action: nil)
  var onLoad: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    button.bezelStyle = .inline
    button.font = .systemFont(ofSize: 12)
    button.target = self
    button.action = #selector(loadHistory)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: centerXAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setLoading(_ loading: Bool) {
    button.title = loading ? "Loading messages…" : "Load missing messages"
    button.isEnabled = !loading
  }

  @objc private func loadHistory() {
    onLoad?()
  }
}
