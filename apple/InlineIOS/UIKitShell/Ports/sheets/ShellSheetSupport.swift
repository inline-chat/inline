import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import UIKit

// Shared pieces for the UIKit sheet ports: sheet wrapping/closing that keeps `router.presentedSheet`
// in sync, a peer row cell (avatar or thread icon, title, subtitle, selection), an emoji + title
// field cell, a choice list, and a share sheet helper. iOS 15 APIs only.

// MARK: - Sheet wrapping and closing

@MainActor
enum ShellSheetSupport {
  /// Wraps `root` in a page sheet. A swipe-down clears the router's sheet when this is the
  /// shell's router-driven sheet (`sheetDidDismiss` checks identity, so it is harmless otherwise).
  ///
  /// `SheetNavigationController` makes itself the presentation delegate in `viewDidLoad`, which
  /// replaces the shell's `SheetDismissalRelay`; `onDismiss` forwards the swipe instead.
  static func wrap(
    _ root: UIViewController,
    shell: MainShellController,
    detents: [CompatSheetDetent] = [.large]
  ) -> SheetNavigationController {
    let navigation = SheetNavigationController(root: root, showsCancel: false)
    navigation.modalPresentationStyle = .pageSheet
    navigation.compatConfigureSheet(detents: detents, prefersGrabber: detents.count > 1)
    navigation.onDismiss = { [weak shell, weak navigation] in
      guard let shell, let navigation else { return }
      shell.sheetDidDismiss(navigation)
    }
    return navigation
  }
}

extension UIViewController {
  /// Closes the sheet this controller sits in. Clears `router.presentedSheet` first when the
  /// sheet is the shell's router-driven one, so the shell does not dismiss it a second time.
  @MainActor
  func closeShellSheet(_ shell: MainShellController, completion: (() -> Void)? = nil) {
    let host = navigationController ?? self
    shell.sheetDidDismiss(host)
    if host.presentingViewController != nil {
      host.dismiss(animated: true, completion: completion)
    } else {
      completion?()
    }
  }

  /// Presents a share sheet anchored to `sourceView` or `barButtonItem` on iPad.
  @MainActor
  func presentShareSheet(items: [Any], sourceView: UIView? = nil, barButtonItem: UIBarButtonItem? = nil) {
    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      if let barButtonItem {
        popover.barButtonItem = barButtonItem
      } else {
        let anchor: UIView = sourceView ?? view
        popover.sourceView = anchor
        popover.sourceRect = anchor.bounds
      }
    }
    topmostPresented.present(activity, animated: true)
  }
}

// MARK: - Peer row cell

/// Avatar (user photo/initials, thread icon or symbol), title, subtitle, optional trailing text or
/// symbol, and an optional leading selection circle. Used through `FormRow.custom`.
final class SheetPeerRowCell: UITableViewCell {
  static let reuseIdentifier = "SheetPeerRowCell"

  enum Identity: Hashable {
    case user(UserInfo)
    case thread(ThreadIconDescriptor)
    case symbol(String)
  }

  enum Selection: Hashable {
    case none
    case unselected
    case selected
  }

  struct Content: Hashable {
    var identity: Identity
    var title: String
    var subtitle: String?
    var trailingText: String?
    var trailingSymbol: String?
    var selection: Selection = .none
    var showsPin = false
    var showsUnread = false
    var isEnabled = true
    var avatarSize: CGFloat = 38
  }

  private let selectionView = UIImageView()
  private let identityContainer = UIView()
  private let avatarView = UserAvatarLayerView()
  private let threadIconView = ThreadIconLayerView()
  private let symbolContainer = UIView()
  private let symbolView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let pinView = UIImageView(image: UIImage(systemName: "pin.fill"))
  private let unreadDot = UIView()
  private let trailingLabel = UILabel()
  private let trailingSymbolView = UIImageView()
  private var identityWidth: NSLayoutConstraint!
  private var identityHeight: NSLayoutConstraint!

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: .default, reuseIdentifier: reuseIdentifier)
    setUp()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUp() {
    selectionView.preferredSymbolConfiguration = .init(pointSize: 21, weight: .medium)
    selectionView.contentMode = .center
    selectionView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      selectionView.widthAnchor.constraint(equalToConstant: 26),
      selectionView.heightAnchor.constraint(equalToConstant: 26),
    ])

    identityContainer.translatesAutoresizingMaskIntoConstraints = false
    symbolContainer.backgroundColor = .tertiarySystemFill
    symbolContainer.clipsToBounds = true
    symbolView.contentMode = .center
    symbolView.tintColor = .secondaryLabel
    symbolView.translatesAutoresizingMaskIntoConstraints = false
    symbolContainer.addSubview(symbolView)
    NSLayoutConstraint.activate([
      symbolView.centerXAnchor.constraint(equalTo: symbolContainer.centerXAnchor),
      symbolView.centerYAnchor.constraint(equalTo: symbolContainer.centerYAnchor),
    ])
    for view in [avatarView, threadIconView, symbolContainer] as [UIView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      identityContainer.addSubview(view)
      NSLayoutConstraint.activate([
        view.centerXAnchor.constraint(equalTo: identityContainer.centerXAnchor),
        view.centerYAnchor.constraint(equalTo: identityContainer.centerYAnchor),
        view.widthAnchor.constraint(equalTo: identityContainer.widthAnchor),
        view.heightAnchor.constraint(equalTo: identityContainer.heightAnchor),
      ])
    }
    identityWidth = identityContainer.widthAnchor.constraint(equalToConstant: 38)
    identityHeight = identityContainer.heightAnchor.constraint(equalToConstant: 38)
    identityWidth.isActive = true
    identityHeight.isActive = true

    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    textStack.axis = .vertical
    textStack.spacing = 1
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

    pinView.tintColor = .secondaryLabel
    pinView.preferredSymbolConfiguration = .init(pointSize: 11, weight: .semibold)
    pinView.setContentHuggingPriority(.required, for: .horizontal)
    unreadDot.backgroundColor = .tintColor
    unreadDot.layer.cornerRadius = 4
    unreadDot.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      unreadDot.widthAnchor.constraint(equalToConstant: 8),
      unreadDot.heightAnchor.constraint(equalToConstant: 8),
    ])
    trailingLabel.font = .preferredFont(forTextStyle: .subheadline)
    trailingLabel.adjustsFontForContentSizeCategory = true
    trailingLabel.textColor = .secondaryLabel
    trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
    trailingSymbolView.tintColor = .secondaryLabel
    trailingSymbolView.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)
    trailingSymbolView.setContentHuggingPriority(.required, for: .horizontal)

    let row = UIStackView(arrangedSubviews: [
      selectionView, identityContainer, textStack, pinView, unreadDot, trailingLabel, trailingSymbolView,
    ])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 12
    row.setCustomSpacing(6, after: pinView)
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
    ])
  }

  func configure(_ content: Content) {
    identityWidth.constant = content.avatarSize
    identityHeight.constant = content.avatarSize

    switch content.identity {
    case let .user(userInfo):
      avatarView.isHidden = false
      threadIconView.isHidden = true
      symbolContainer.isHidden = true
      avatarView.configure(with: userInfo, size: content.avatarSize)
    case let .thread(descriptor):
      avatarView.isHidden = true
      threadIconView.isHidden = false
      symbolContainer.isHidden = true
      threadIconView.configure(descriptor, size: .compact(content.avatarSize), shape: .circle, symbolColor: .mutedPrimary)
    case let .symbol(name):
      avatarView.isHidden = true
      threadIconView.isHidden = true
      symbolContainer.isHidden = false
      symbolContainer.layer.cornerRadius = content.avatarSize / 2
      symbolView.image = UIImage(
        systemName: name,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: content.avatarSize * 0.42, weight: .medium)
      )
    }

    switch content.selection {
    case .none:
      selectionView.isHidden = true
    case .unselected:
      selectionView.isHidden = false
      selectionView.image = UIImage(systemName: "circle")
      selectionView.tintColor = .tertiaryLabel
    case .selected:
      selectionView.isHidden = false
      selectionView.image = UIImage(systemName: "checkmark.circle.fill")
      selectionView.tintColor = .tintColor
    }

    titleLabel.text = content.title
    titleLabel.textColor = content.isEnabled ? .label : .tertiaryLabel
    subtitleLabel.text = content.subtitle
    subtitleLabel.isHidden = content.subtitle?.isEmpty ?? true
    pinView.isHidden = !content.showsPin
    unreadDot.isHidden = !content.showsUnread
    trailingLabel.text = content.trailingText
    trailingLabel.isHidden = content.trailingText == nil
    trailingSymbolView.image = content.trailingSymbol.flatMap { UIImage(systemName: $0) }
    trailingSymbolView.isHidden = content.trailingSymbol == nil

    isAccessibilityElement = true
    accessibilityLabel = [content.title, content.subtitle, content.trailingText]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
    var traits: UIAccessibilityTraits = .button
    if content.selection == .selected { traits.insert(.selected) }
    if !content.isEnabled { traits.insert(.notEnabled) }
    accessibilityTraits = traits
  }
}

extension FormRow {
  /// A `SheetPeerRowCell` row. Register the cell with `SheetPeerRowCell.register(in:)`.
  @MainActor
  static func peer(
    _ id: String,
    _ content: SheetPeerRowCell.Content,
    onSelect: (@MainActor () -> Void)? = nil
  ) -> FormRow {
    FormRow.custom(
      id,
      reuseIdentifier: SheetPeerRowCell.reuseIdentifier,
      contentKey: content,
      isEnabled: content.isEnabled,
      onSelect: onSelect
    ) { cell in
      (cell as? SheetPeerRowCell)?.configure(content)
    }
  }
}

extension SheetPeerRowCell {
  static func register(in tableView: UITableView) {
    tableView.register(SheetPeerRowCell.self, forCellReuseIdentifier: reuseIdentifier)
  }
}

// MARK: - Emoji + title field cell

/// A round emoji well and a title field side by side, as the SwiftUI Create Space and Create
/// Thread forms draw them. The emoji keeps only its first character and hands focus to the title.
final class SheetEmojiTitleCell: UITableViewCell, UITextFieldDelegate {
  static let reuseIdentifier = "SheetEmojiTitleCell"

  /// The emoji keyboard (undocumented raw value, as the SwiftUI forms use).
  static let emojiKeyboard = UIKeyboardType(rawValue: 124) ?? .default

  let emojiField = UITextField()
  let titleField = UITextField()
  private let well = UIView()
  private let placeholderIcon = UIImageView(image: UIImage(systemName: "face.smiling"))

  var onEmojiChange: (@MainActor (String) -> Void)?
  var onTitleChange: (@MainActor (String) -> Void)?
  var onSubmit: (@MainActor () -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none

    well.backgroundColor = UIColor.tintColor.withAlphaComponent(0.12)
    well.layer.cornerRadius = 26
    well.translatesAutoresizingMaskIntoConstraints = false
    placeholderIcon.tintColor = .tintColor
    placeholderIcon.preferredSymbolConfiguration = .init(textStyle: .title2)
    placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
    placeholderIcon.isAccessibilityElement = false
    emojiField.font = .systemFont(ofSize: 28)
    emojiField.textAlignment = .center
    emojiField.keyboardType = Self.emojiKeyboard
    emojiField.tintColor = .clear
    emojiField.autocorrectionType = .no
    emojiField.accessibilityLabel = String(localized: "Emoji")
    emojiField.delegate = self
    emojiField.translatesAutoresizingMaskIntoConstraints = false
    emojiField.addTarget(self, action: #selector(emojiChanged), for: .editingChanged)
    well.addSubview(placeholderIcon)
    well.addSubview(emojiField)
    well.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focusEmoji)))

    titleField.font = .preferredFont(forTextStyle: .body)
    titleField.adjustsFontForContentSizeCategory = true
    titleField.clearButtonMode = .whileEditing
    titleField.returnKeyType = .done
    titleField.delegate = self
    titleField.translatesAutoresizingMaskIntoConstraints = false
    titleField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)

    contentView.addSubview(well)
    contentView.addSubview(titleField)
    NSLayoutConstraint.activate([
      well.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      well.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      well.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      well.widthAnchor.constraint(equalToConstant: 52),
      well.heightAnchor.constraint(equalToConstant: 52),
      placeholderIcon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
      placeholderIcon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
      emojiField.leadingAnchor.constraint(equalTo: well.leadingAnchor),
      emojiField.trailingAnchor.constraint(equalTo: well.trailingAnchor),
      emojiField.topAnchor.constraint(equalTo: well.topAnchor),
      emojiField.bottomAnchor.constraint(equalTo: well.bottomAnchor),
      titleField.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 12),
      titleField.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      titleField.centerYAnchor.constraint(equalTo: well.centerYAnchor),
      titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    emoji: String,
    title: String,
    placeholder: String,
    autocapitalization: UITextAutocapitalizationType,
    isEnabled: Bool
  ) {
    if !emojiField.isFirstResponder { emojiField.text = emoji }
    if !titleField.isFirstResponder { titleField.text = title }
    titleField.placeholder = placeholder
    titleField.autocapitalizationType = autocapitalization
    emojiField.isEnabled = isEnabled
    titleField.isEnabled = isEnabled
    well.isUserInteractionEnabled = isEnabled
    updatePlaceholder()
  }

  private func updatePlaceholder() {
    placeholderIcon.isHidden = !(emojiField.text?.isEmpty ?? true) || emojiField.isFirstResponder
  }

  @objc private func focusEmoji() {
    emojiField.becomeFirstResponder()
  }

  @objc private func emojiChanged() {
    let text = emojiField.text ?? ""
    if let first = text.first {
      let emoji = String(first)
      if text != emoji { emojiField.text = emoji }
      onEmojiChange?(emoji)
      updatePlaceholder()
      titleField.becomeFirstResponder()
    } else {
      onEmojiChange?("")
      updatePlaceholder()
    }
  }

  @objc private func titleChanged() {
    onTitleChange?(titleField.text ?? "")
  }

  func textFieldDidBeginEditing(_ textField: UITextField) { updatePlaceholder() }
  func textFieldDidEndEditing(_ textField: UITextField) { updatePlaceholder() }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === titleField {
      textField.resignFirstResponder()
      onSubmit?()
    }
    return true
  }
}

extension FormRow {
  /// A `SheetEmojiTitleCell` row. Register with `tableView.register(SheetEmojiTitleCell.self, …)`.
  @MainActor
  static func emojiTitle(
    _ id: String,
    emoji: String,
    title: String,
    placeholder: String,
    autocapitalization: UITextAutocapitalizationType = .sentences,
    isEnabled: Bool = true,
    onEmojiChange: @escaping @MainActor (String) -> Void,
    onTitleChange: @escaping @MainActor (String) -> Void,
    onSubmit: @escaping @MainActor () -> Void
  ) -> FormRow {
    FormRow.custom(
      id,
      reuseIdentifier: SheetEmojiTitleCell.reuseIdentifier,
      contentKey: AnyHashable([placeholder, isEnabled ? "1" : "0"]),
      isEnabled: isEnabled
    ) { cell in
      guard let cell = cell as? SheetEmojiTitleCell else { return }
      cell.onEmojiChange = onEmojiChange
      cell.onTitleChange = onTitleChange
      cell.onSubmit = onSubmit
      cell.configure(
        emoji: emoji,
        title: title,
        placeholder: placeholder,
        autocapitalization: autocapitalization,
        isEnabled: isEnabled
      )
    }
  }
}

// MARK: - Choice list

/// A pushed list of check rows; picking one calls back and pops.
@MainActor
final class SheetChoiceViewController: FormViewController {
  struct Option {
    var id: String
    var title: String
    var subtitle: String?
    var systemImage: String?
  }

  struct Group {
    var header: String?
    var options: [Option]
  }

  private let groups: [Group]
  private let selectedID: String?
  private let onSelect: @MainActor (String) -> Void

  init(title: String, groups: [Group], selectedID: String?, onSelect: @escaping @MainActor (String) -> Void) {
    self.groups = groups
    self.selectedID = selectedID
    self.onSelect = onSelect
    super.init(style: .insetGrouped)
    self.title = title
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    for (index, group) in groups.enumerated() {
      FormSection("group-\(index)", header: group.header) {
        for option in group.options {
          FormRow.check(
            option.id,
            option.title,
            subtitle: option.subtitle,
            icon: option.systemImage.map { FormIcon(systemName: $0) },
            isSelected: option.id == selectedID
          ) { [weak self] in
            self?.choose(option.id)
          }
        }
      }
    }
  }

  private func choose(_ id: String) {
    onSelect(id)
    navigationController?.popViewController(animated: true)
  }
}
