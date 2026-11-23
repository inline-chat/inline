#if canImport(UIKit)
import InlineCompatUI
import UIKit

// MARK: - Empty state (ContentUnavailableView / UIContentUnavailableConfiguration: iOS 17)

/// Centered symbol, title, message and optional button. Same role as ContentUnavailableView.
public final class EmptyStateView: UIView {
  public let imageView = UIImageView()
  public let titleLabel = UILabel()
  public let messageLabel = UILabel()
  public let button = UIButton(type: .system)
  private var action: (@MainActor () -> Void)?

  public init(
    systemImage: String? = nil,
    title: String,
    message: String? = nil,
    actionTitle: String? = nil,
    action: (@MainActor () -> Void)? = nil
  ) {
    super.init(frame: .zero)
    imageView.preferredSymbolConfiguration = .init(pointSize: 44, weight: .regular)
    imageView.tintColor = .secondaryLabel
    imageView.contentMode = .scaleAspectFit
    titleLabel.font = .preferredFont(forTextStyle: .title3).withWeight(.semibold)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    messageLabel.font = .preferredFont(forTextStyle: .subheadline)
    messageLabel.adjustsFontForContentSizeCategory = true
    messageLabel.textColor = .secondaryLabel
    messageLabel.textAlignment = .center
    messageLabel.numberOfLines = 0
    button.addTarget(self, action: #selector(tapped), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [imageView, titleLabel, messageLabel, button])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 8
    stack.setCustomSpacing(14, after: imageView)
    stack.setCustomSpacing(16, after: messageLabel)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor, constant: -20),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: readableContentGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: readableContentGuide.trailingAnchor, constant: -16),
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
    ])
    update(systemImage: systemImage, title: title, message: message, actionTitle: actionTitle, action: action)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func update(
    systemImage: String? = nil,
    title: String,
    message: String? = nil,
    actionTitle: String? = nil,
    action: (@MainActor () -> Void)? = nil
  ) {
    imageView.image = systemImage.flatMap { UIImage(systemName: $0) }
    imageView.isHidden = imageView.image == nil
    titleLabel.text = title
    messageLabel.text = message
    messageLabel.isHidden = message?.isEmpty ?? true
    button.setTitle(actionTitle, for: .normal)
    button.isHidden = actionTitle == nil
    self.action = action
  }

  @objc private func tapped() { action?() }
}

// MARK: - Primary button

/// Large filled button with a loading state (UIButton.Configuration, iOS 15).
public final class PrimaryButton: UIButton {
  public var title: String {
    didSet { updateConfiguration() }
  }

  public var isLoading = false {
    didSet {
      updateConfiguration()
      isUserInteractionEnabled = !isLoading
    }
  }

  public var style: Style = .filled {
    didSet { updateConfiguration() }
  }

  public enum Style { case filled, tinted, plain }

  private var onTap: (@MainActor () -> Void)?

  public init(title: String, style: Style = .filled, action: (@MainActor () -> Void)? = nil) {
    self.title = title
    self.style = style
    onTap = action
    super.init(frame: .zero)
    addTarget(self, action: #selector(tapped), for: .touchUpInside)
    updateConfiguration()
    heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func setAction(_ action: @escaping @MainActor () -> Void) { onTap = action }

  public override func updateConfiguration() {
    var config: UIButton.Configuration
    switch style {
    case .filled: config = .filled()
    case .tinted: config = .tinted()
    case .plain: config = .plain()
    }
    config.cornerStyle = .large
    config.buttonSize = .large
    var attributes = AttributeContainer()
    attributes.font = UIFont.preferredFont(forTextStyle: .headline)
    config.attributedTitle = AttributedString(title, attributes: attributes)
    config.showsActivityIndicator = isLoading
    configuration = config
  }

  @objc private func tapped() { onTap?() }
}

// MARK: - Alerts

extension UIViewController {
  /// Simple OK alert.
  public func presentAlert(title: String, message: String? = nil, buttonTitle: String = "OK") {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: buttonTitle, style: .cancel))
    topmostPresented.present(alert, animated: true)
  }

  public func presentError(_ error: Error, title: String = "Something went wrong") {
    presentAlert(title: title, message: error.localizedDescription)
  }

  /// Confirmation dialog; resumes with true when the confirm action is chosen.
  public func confirm(
    title: String,
    message: String? = nil,
    confirmTitle: String,
    destructive: Bool = false,
    cancelTitle: String = "Cancel",
    style: UIAlertController.Style = .alert,
    sourceView: UIView? = nil
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: title, message: message, preferredStyle: style)
      alert.addAction(UIAlertAction(title: confirmTitle, style: destructive ? .destructive : .default) { _ in
        continuation.resume(returning: true)
      })
      alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
        continuation.resume(returning: false)
      })
      if let popover = alert.popoverPresentationController {
        popover.sourceView = sourceView ?? view
        if sourceView == nil {
          popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 0, height: 0)
        }
      }
      topmostPresented.present(alert, animated: true)
    }
  }

  /// Text prompt; resumes with the entered text, or nil when cancelled.
  public func prompt(
    title: String,
    message: String? = nil,
    placeholder: String? = nil,
    initialText: String? = nil,
    confirmTitle: String = "Save"
  ) async -> String? {
    await withCheckedContinuation { continuation in
      let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
      alert.addTextField { field in
        field.placeholder = placeholder
        field.text = initialText
        field.clearButtonMode = .whileEditing
      }
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
        continuation.resume(returning: nil)
      })
      alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { [weak alert] _ in
        continuation.resume(returning: alert?.textFields?.first?.text ?? "")
      })
      topmostPresented.present(alert, animated: true)
    }
  }

  /// The controller currently on top of this one's presentation chain.
  public var topmostPresented: UIViewController {
    var top: UIViewController = self
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}

// MARK: - Sheets

/// Navigation controller for modal flows, with an optional Cancel button on the root.
open class SheetNavigationController: UINavigationController, UIAdaptivePresentationControllerDelegate {
  /// Called when the sheet is dismissed by swipe or Cancel.
  public var onDismiss: (@MainActor () -> Void)?

  public init(root: UIViewController, showsCancel: Bool = true) {
    super.init(nibName: nil, bundle: nil)
    // Before anything touches `presentationController`, or the style is ignored.
    modalPresentationStyle = .pageSheet
    setViewControllers([root], animated: false)
    if showsCancel, root.navigationItem.leftBarButtonItem == nil {
      root.navigationItem.leftBarButtonItem = UIBarButtonItem(
        systemItem: .cancel,
        primaryAction: UIAction { [weak self] _ in
          self?.dismiss(animated: true) { self?.onDismiss?() }
        }
      )
    }
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  open override func viewDidLoad() {
    super.viewDidLoad()
    presentationController?.delegate = self
  }

  public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    onDismiss?()
  }
}

extension UIViewController {
  /// Presents `controller` in a sheet navigation controller.
  @discardableResult
  public func presentSheet(
    _ controller: UIViewController,
    detents: [CompatSheetDetent] = [.large],
    showsCancel: Bool = true,
    onDismiss: (@MainActor () -> Void)? = nil
  ) -> SheetNavigationController {
    let navigation = SheetNavigationController(root: controller, showsCancel: showsCancel)
    navigation.onDismiss = onDismiss
    navigation.compatConfigureSheet(detents: detents, prefersGrabber: detents.count > 1)
    topmostPresented.present(navigation, animated: true)
    return navigation
  }
}

// MARK: - Loading overlay

/// Dimmed spinner covering a view while a blocking action runs.
public final class LoadingOverlay: UIView {
  private let spinner = UIActivityIndicatorView(style: .large)

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    spinner.startAnimating()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @discardableResult
  public static func show(in view: UIView) -> LoadingOverlay {
    let overlay = LoadingOverlay(frame: view.bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.alpha = 0
    view.addSubview(overlay)
    UIView.animate(withDuration: 0.15) { overlay.alpha = 1 }
    return overlay
  }

  public func hide() {
    UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }) { _ in
      self.removeFromSuperview()
    }
  }
}

// MARK: - Fonts

extension UIFont {
  public func withWeight(_ weight: UIFont.Weight) -> UIFont {
    let descriptor = fontDescriptor.addingAttributes([
      .traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    return UIFont(descriptor: descriptor, size: 0)
  }

  /// Rounded design variant (SF Pro Rounded), falling back to the same font.
  public var rounded: UIFont {
    guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
    return UIFont(descriptor: descriptor, size: 0)
  }
}

// MARK: - Layout

extension UIView {
  /// Pins edges to `other` (or its layout guide) with optional insets.
  public func pinEdges(to other: UIView, insets: UIEdgeInsets = .zero, safeArea: Bool = false) {
    translatesAutoresizingMaskIntoConstraints = false
    let top = safeArea ? other.safeAreaLayoutGuide.topAnchor : other.topAnchor
    let bottom = safeArea ? other.safeAreaLayoutGuide.bottomAnchor : other.bottomAnchor
    NSLayoutConstraint.activate([
      topAnchor.constraint(equalTo: top, constant: insets.top),
      leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
      trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
      bottomAnchor.constraint(equalTo: bottom, constant: -insets.bottom),
    ])
  }
}
#endif
