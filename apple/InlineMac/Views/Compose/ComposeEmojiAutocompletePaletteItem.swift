import AppKit
import InlineKit

final class ComposeEmojiAutocompletePaletteItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("ComposeEmojiAutocompletePaletteItem")

  private let emojiLabel = NSTextField(labelWithString: "")

  private var currentItem: ComposeAutocompleteItem?
  private var trackingArea: NSTrackingArea?
  private var isHovered = false

  var isActive = false {
    didSet {
      updateAppearance()
    }
  }

  override var isSelected: Bool {
    didSet {
      isActive = isSelected
      updateAppearance()
    }
  }

  override func loadView() {
    view = NSView()
    setupView()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    view.layer?.cornerRadius = min(view.bounds.width, view.bounds.height) / 2
    updateTrackingArea()
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updateAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateAppearance()
  }

  func configure(with item: ComposeAutocompleteItem, selected: Bool) {
    if currentItem == item, isActive == selected { return }
    currentItem = item
    isActive = selected

    emojiLabel.stringValue = item.emoji ?? ""
    view.toolTip = item.title
    view.setAccessibilityLabel(item.title)
  }

  private func setupView() {
    view.wantsLayer = true
    view.layer?.cornerRadius = 17
    view.layer?.borderWidth = 0

    emojiLabel.isBordered = false
    emojiLabel.isEditable = false
    emojiLabel.isSelectable = false
    emojiLabel.alignment = .center
    emojiLabel.backgroundColor = .clear
    emojiLabel.font = .systemFont(ofSize: 22)
    emojiLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emojiLabel)

    NSLayoutConstraint.activate([
      emojiLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emojiLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emojiLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -1),
    ])

    updateAppearance()
  }

  private func updateTrackingArea() {
    if let trackingArea {
      view.removeTrackingArea(trackingArea)
    }

    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
    self.trackingArea = trackingArea
    view.addTrackingArea(trackingArea)
  }

  private func updateAppearance() {
    let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let bgColor: NSColor

    if isActive {
      bgColor = NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.52 : 0.34)
    } else if isHovered {
      bgColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.12 : 0.07)
    } else {
      bgColor = .clear
    }

    view.layer?.backgroundColor = bgColor.resolvedColor(with: view.effectiveAppearance).cgColor
  }
}
