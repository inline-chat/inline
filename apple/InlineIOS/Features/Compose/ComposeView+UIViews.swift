import UIKit

extension ComposeView {
  func makeTextView() -> ComposeTextView {
    let view = ComposeTextView(composeView: self)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.delegate = self
    return view
  }

  func makeSendButton() -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.frame = CGRect(origin: .zero, size: buttonSize)

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = ThemeManager.shared.selected.accent
    config.cornerStyle = .capsule

    button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

    button.configurationUpdateHandler = { [weak button] _ in
      guard let button else { return }

      let config = button.configuration

      if button.isHighlighted {
        UIView.animate(
          withDuration: 0.15,
          delay: 0,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
          animations: {
            button.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
          }
        )
      } else {
        UIView.animate(
          withDuration: 0.12,
          delay: 0.05,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn],
          animations: {
            button.transform = .identity
          }
        )
      }

      button.configuration = config
    }

    button.configuration = config
    button.isUserInteractionEnabled = true

    // Hide initially
    button.alpha = 0.0

    return button
  }

  func makePlusButton() -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    var config: UIButton.Configuration
    if #available(iOS 26.0, *) {
      config = UIButton.Configuration.glass()
    } else {
      config = UIButton.Configuration.plain()
      config.background.backgroundColor = .secondarySystemBackground
    }

    config.image = UIImage(systemName: "plus")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    )
    config.baseForegroundColor = .secondaryLabel
    button.configuration = config
    button.layer.cornerRadius = 20
    button.clipsToBounds = true

    let libraryAction = UIAction(
      title: "Photos",
      image: UIImage(systemName: "photo.on.rectangle.angled"),
      handler: { [weak self] _ in
        self?.presentPicker()
      }
    )

    let cameraAction = UIAction(
      title: "Camera",
      image: UIImage(systemName: "camera"),
      handler: { [weak self] _ in
        self?.presentCamera()
      }
    )

    let fileAction = UIAction(
      title: "File",
      image: UIImage(systemName: "folder"),
      handler: { [weak self] _ in
        self?.presentFileManager()
      }
    )
    button.menu = UIMenu(children: [libraryAction, cameraAction, fileAction])
    button.showsMenuAsPrimaryAction = true

    return button
  }

  func makeComposeAndButtonContainer() -> UIView {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = true
    view.backgroundColor = .clear

    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect(style: .regular)
      let glassView = UIVisualEffectView(effect: glassEffect)
      glassView.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(glassView)

      NSLayoutConstraint.activate([
        glassView.topAnchor.constraint(equalTo: view.topAnchor),
        glassView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        glassView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        glassView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])

      glassView.layer.cornerRadius = 20
      glassView.layer.cornerCurve = .continuous
      glassView.layer.masksToBounds = true

    } else {
      // view.layer.backgroundColor = UIColor.systemBackground.cgColor
      view.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.8)
      view.layer.cornerRadius = 20
      view.layer.cornerCurve = .continuous
      view.clipsToBounds = true
    }

    return view
  }

  func makeEmbedContainerView() -> UIView {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = true
    view.backgroundColor = .clear
    view.clipsToBounds = true
    view.isHidden = true
    return view
  }
}
