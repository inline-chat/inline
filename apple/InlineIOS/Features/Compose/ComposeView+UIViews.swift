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

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "plus")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = .secondaryLabel
    config.background.backgroundColor = .secondarySystemBackground
    button.configuration = config
    button.layer.cornerRadius = 16
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
}
