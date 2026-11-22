import Combine
import InlineCompatUI
import UIKit

/// Draws `ToastManager.currentToast` in UIKit, replacing the SwiftUI `.toastView()` overlay.
///
/// Lives in a passthrough window above the app so toasts show over sheets too. Liquid Glass
/// capsule on iOS 26+, system chrome blur before.
@MainActor
final class ToastPresenter {
  static let shared = ToastPresenter()

  private var windows: [ObjectIdentifier: PassthroughWindow] = [:]
  private var cancellable: AnyCancellable?
  private var currentID: UUID?

  private init() {
    cancellable = ToastManager.shared.$currentToast
      .receive(on: DispatchQueue.main)
      .sink { [weak self] toast in self?.render(toast) }
  }

  func attach(to window: UIWindow) {
    guard let scene = window.windowScene else { return }
    let overlay = PassthroughWindow(windowScene: scene)
    overlay.windowLevel = .alert + 1
    overlay.backgroundColor = .clear
    overlay.rootViewController = ToastHostController()
    overlay.isHidden = false
    windows[ObjectIdentifier(scene)] = overlay
  }

  private func render(_ toast: ToastData?) {
    for overlay in windows.values {
      (overlay.rootViewController as? ToastHostController)?.show(toast)
    }
    currentID = toast?.id
  }
}

/// Window that only takes touches landing on a toast.
private final class PassthroughWindow: UIWindow {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === rootViewController?.view ? nil : hit
  }
}

private final class ToastHostController: UIViewController {
  private var toastView: ToastCapsuleView?
  private var shownID: UUID?

  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
  }

  func show(_ toast: ToastData?) {
    guard toast?.id != shownID || toast == nil else {
      if let toast { toastView?.update(toast) }
      return
    }
    shownID = toast?.id
    let old = toastView
    toastView = nil
    if let old {
      UIView.animate(withDuration: 0.2, animations: {
        old.alpha = 0
        old.transform = CGAffineTransform(translationX: 0, y: old.isTop ? -12 : 12)
      }, completion: { _ in old.removeFromSuperview() })
    }
    guard let toast else { return }

    let capsule = ToastCapsuleView(toast: toast)
    capsule.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(capsule)
    let guide = view.safeAreaLayoutGuide
    var constraints = [
      capsule.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      capsule.leadingAnchor.constraint(greaterThanOrEqualTo: view.readableContentGuide.leadingAnchor),
      capsule.trailingAnchor.constraint(lessThanOrEqualTo: view.readableContentGuide.trailingAnchor),
    ]
    switch toast.placement {
    case let .topCenter(offset):
      constraints.append(capsule.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8 + offset))
      capsule.isTop = true
    case let .bottomCenter(offset):
      constraints.append(capsule.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -(64 + offset)))
    case nil:
      constraints.append(capsule.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8))
      capsule.isTop = true
    }
    NSLayoutConstraint.activate(constraints)
    toastView = capsule

    capsule.alpha = 0
    capsule.transform = CGAffineTransform(translationX: 0, y: capsule.isTop ? -16 : 16).scaledBy(x: 0.96, y: 0.96)
    UIView.animate(
      withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.45,
      delay: 0,
      usingSpringWithDamping: 0.8,
      initialSpringVelocity: 0,
      options: [.allowUserInteraction]
    ) {
      capsule.alpha = 1
      capsule.transform = .identity
    }
    UIAccessibility.post(notification: .announcement, argument: toast.message)
  }
}

private final class ToastCapsuleView: UIView {
  var isTop = false
  private let material = CompatMaterialView(.glass())
  private let iconView = UIImageView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()
  private let actionButton = UIButton(type: .system)
  private var action: (() -> Void)?

  init(toast: ToastData) {
    super.init(frame: .zero)
    material.translatesAutoresizingMaskIntoConstraints = false
    material.compatSetCornerRadius(22)
    material.clipsToBounds = true
    addSubview(material)
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.12
    layer.shadowRadius = 12
    layer.shadowOffset = CGSize(width: 0, height: 4)

    iconView.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)
    iconView.setContentHuggingPriority(.required, for: .horizontal)
    titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.medium)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.numberOfLines = 2
    detailLabel.font = .preferredFont(forTextStyle: .footnote)
    detailLabel.textColor = .secondaryLabel
    detailLabel.numberOfLines = 2
    actionButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
    actionButton.addTarget(self, action: #selector(tapped), for: .touchUpInside)

    let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
    text.axis = .vertical
    text.spacing = 1
    let row = UIStackView(arrangedSubviews: [spinner, iconView, text, actionButton])
    row.axis = .horizontal
    row.spacing = 10
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    material.contentView.addSubview(row)
    NSLayoutConstraint.activate([
      material.topAnchor.constraint(equalTo: topAnchor),
      material.bottomAnchor.constraint(equalTo: bottomAnchor),
      material.leadingAnchor.constraint(equalTo: leadingAnchor),
      material.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: material.contentView.topAnchor, constant: 11),
      row.bottomAnchor.constraint(equalTo: material.contentView.bottomAnchor, constant: -11),
      row.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor, constant: -16),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    update(toast)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(_ toast: ToastData) {
    titleLabel.text = toast.message
    detailLabel.text = toast.description
    detailLabel.isHidden = toast.description?.isEmpty ?? true
    action = toast.action
    actionButton.setTitle(toast.actionTitle, for: .normal)
    actionButton.isHidden = toast.action == nil || toast.actionTitle == nil
    let loading = toast.type == .loading
    spinner.isHidden = !loading
    if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    let symbol = toast.systemImage ?? Self.defaultSymbol(toast.type)
    iconView.image = symbol.flatMap { UIImage(systemName: $0) }
    iconView.isHidden = loading || iconView.image == nil
    iconView.tintColor = Self.tint(toast.type)
  }

  private static func defaultSymbol(_ type: ToastType) -> String? {
    switch type {
    case .success: "checkmark.circle.fill"
    case .error: "exclamationmark.triangle.fill"
    case .info: "info.circle.fill"
    case .loading: nil
    }
  }

  private static func tint(_ type: ToastType) -> UIColor {
    switch type {
    case .success: .systemGreen
    case .error: .systemRed
    case .info, .loading: .label
    }
  }

  @objc private func tapped() {
    action?()
    ToastManager.shared.hideToast()
  }
}
