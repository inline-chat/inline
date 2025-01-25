
import AppKit
import Nuke
import NukeUI

class PhotoLazyImageView: NSView {
  private let imageView = LazyImageView()
  private var corners: [CornerRadius] = []

  var url: URL? {
    get { imageView.url }
    set { imageView.url = newValue }
  }

  var onStart: ((ImageTask) -> Void)? {
    get { imageView.onStart }
    set { imageView.onStart = newValue }
  }

  var onSuccess: ((ImageResponse) -> Void)? {
    get { imageView.onSuccess }
    set {
      imageView.onSuccess = { [weak self] response in
        newValue?(response)
        self?.updateCornerMask()
      }
    }
  }

  var onFailure: ((Error) -> Void)? {
    get { imageView.onFailure }
    set { imageView.onFailure = newValue }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    wantsLayer = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.transition = .fadeIn(duration: 0.3)
    imageView.wantsLayer = true
    addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func setCorners(_ corners: [CornerRadius]) {
    self.corners = corners
    updateCornerMask()
  }

  private func updateCornerMask() {
    guard !corners.isEmpty else { return }
    applyCornerMask(to: self, corners: corners)
  }

  override func layout() {
    super.layout()
    updateCornerMask()
  }
}
