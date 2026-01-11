import SwiftUI
import UIKit

final class CircularProgressHostingView: UIView {
  private let hostingController = UIHostingController(rootView: CircularProgressRing(progress: 0))

  override init(frame: CGRect) {
    super.init(frame: frame)

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.backgroundColor = .clear
    hostingController.view.isUserInteractionEnabled = false

    addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setProgress(_ progress: Double) {
    let clamped = min(max(progress, 0), 1)
    hostingController.rootView = CircularProgressRing(progress: clamped)
  }
}

private struct CircularProgressRing: View {
  let progress: Double

  var body: some View {
    ProgressView(value: progress)
      .progressViewStyle(.circular)
      .tint(Color.white)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
