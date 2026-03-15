import AppKit
import InlineKit

final class CommandCompletionMenuItem: NSTableCellView {
  private let containerView = NSView()
  private let commandLabel = NSTextField()
  private let descriptionLabel = NSTextField()
  private let botLabel = NSTextField()

  private var _isSelected = false

  var isSelected: Bool {
    get { _isSelected }
    set {
      guard _isSelected != newValue else { return }
      _isSelected = newValue
      updateAppearance()
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    containerView.wantsLayer = true
    containerView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(containerView)

    commandLabel.isBordered = false
    commandLabel.isEditable = false
    commandLabel.backgroundColor = .clear
    commandLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    commandLabel.lineBreakMode = .byTruncatingTail
    commandLabel.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(commandLabel)

    descriptionLabel.isBordered = false
    descriptionLabel.isEditable = false
    descriptionLabel.backgroundColor = .clear
    descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
    descriptionLabel.lineBreakMode = .byTruncatingTail
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(descriptionLabel)

    botLabel.isBordered = false
    botLabel.isEditable = false
    botLabel.backgroundColor = .clear
    botLabel.font = .systemFont(ofSize: 11, weight: .medium)
    botLabel.alignment = .right
    botLabel.lineBreakMode = .byTruncatingTail
    botLabel.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(botLabel)

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

      commandLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
      commandLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 5),

      botLabel.leadingAnchor.constraint(greaterThanOrEqualTo: commandLabel.trailingAnchor, constant: 8),
      botLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
      botLabel.centerYAnchor.constraint(equalTo: commandLabel.centerYAnchor),

      descriptionLabel.leadingAnchor.constraint(equalTo: commandLabel.leadingAnchor),
      descriptionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
      descriptionLabel.topAnchor.constraint(equalTo: commandLabel.bottomAnchor, constant: 1),
      descriptionLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -5),
    ])

    commandLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    botLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    updateAppearance()
  }

  func configure(with suggestion: PeerBotCommandSuggestion) {
    commandLabel.stringValue = "/\(suggestion.command)"
    descriptionLabel.stringValue = suggestion.description

    if suggestion.isAmbiguous, let botLabelText = suggestion.botLabel {
      botLabel.stringValue = botLabelText
      botLabel.isHidden = false
    } else {
      botLabel.stringValue = ""
      botLabel.isHidden = true
    }
  }

  private func updateAppearance() {
    if isSelected {
      containerView.layer?.backgroundColor = NSColor.accent.cgColor
      commandLabel.textColor = .white
      descriptionLabel.textColor = NSColor.white.withAlphaComponent(0.9)
      botLabel.textColor = NSColor.white.withAlphaComponent(0.9)
    } else {
      containerView.layer?.backgroundColor = NSColor.clear.cgColor
      commandLabel.textColor = .labelColor
      descriptionLabel.textColor = .secondaryLabelColor
      botLabel.textColor = .tertiaryLabelColor
    }
  }

  override func draw(_ dirtyRect: NSRect) {}
}
