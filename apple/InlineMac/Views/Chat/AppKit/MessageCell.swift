// MessageCell.swift
import AppKit
import InlineKit
import SwiftUI

// MessageCell.swift
final class MessageCell: NSCollectionViewItem {
  static let reuseIdentifier = "MessageCell"

  private lazy var containerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var colorView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = 15
    view.layer?.backgroundColor = NSColor.systemBlue.cgColor
    return view
  }()

  private lazy var messageTextField: NSTextField = {
    let field = NSTextField()
    field.translatesAutoresizingMaskIntoConstraints = false
    field.isEditable = false
    field.isBordered = false
    field.drawsBackground = false
    field.cell?.wraps = true
    field.cell?.usesSingleLineMode = false
    field.lineBreakMode = .byWordWrapping
    return field
  }()

  override public var textField: NSTextField? {
    get { messageTextField }
    set { /* We don't need to handle setting */  }
  }

  override func loadView() {
    view = NSView()
    view.wantsLayer = true
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupViews()
    setupMenu()
  }

  private func setupViews() {
    view.addSubview(containerView)
    containerView.addSubview(colorView)
    containerView.addSubview(messageTextField)

    NSLayoutConstraint.activate([
      // Container takes full width
      containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      containerView.topAnchor.constraint(equalTo: view.topAnchor),
      containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      // Avatar/color view
      colorView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      colorView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
      colorView.widthAnchor.constraint(equalToConstant: 30),
      colorView.heightAnchor.constraint(equalToConstant: 30),

      // Message text
      messageTextField.leadingAnchor.constraint(equalTo: colorView.trailingAnchor, constant: 8),
      messageTextField.trailingAnchor.constraint(
        equalTo: containerView.trailingAnchor, constant: -8),
      messageTextField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
      messageTextField.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),
    ])
  }

  private func setupMenu() {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Copy", action: #selector(copyText), keyEquivalent: "c"))
    view.menu = menu
  }

  @objc private func copyText() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(messageTextField.stringValue, forType: .string)
  }

  func configure(with message: FullMessage) {
    messageTextField.stringValue = message.message.text ?? ""

    // Set background color for alternate rows if desired
    if let index = (view.window?.contentView as? NSCollectionView)?.indexPath(for: self)?.item {
      containerView.layer?.backgroundColor =
        index % 2 == 0
        ? NSColor.controlBackgroundColor.cgColor
        : NSColor.controlBackgroundColor.withSystemEffect(.pressed).cgColor
    }
  }
}
