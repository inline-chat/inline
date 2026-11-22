#if canImport(UIKit)
import InlineCompatUI
import UIKit

/// Inset-grouped list screen driven by `makeSections()`.
///
/// `makeSections()` runs inside an observation scope: reading `@Tracked` properties of any
/// `CompatObservable` model there re-renders the form automatically when they change. Call
/// `setNeedsFormUpdate()` for state that is not tracked.
open class FormViewController: UIViewController, UITableViewDelegate {
  public let tableView: UITableView
  public private(set) var sections: [FormSection] = []

  private var dataSource: FormDataSource!
  private var rowsByID: [FormItemID: FormRow] = [:]
  private var hasRendered = false
  private var updateScheduled = false
  private var renderToken: CompatObservationToken?

  public init(style: UITableView.Style = .insetGrouped) {
    tableView = UITableView(frame: .zero, style: style)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Override to describe the screen. Reads of tracked state here are observed.
  @FormSectionsBuilder
  open func makeSections() -> [FormSection] { [] }

  /// Override to register custom cell classes before the first render.
  open func registerCells(in tableView: UITableView) {}

  open override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = tableView.style == .plain ? .systemBackground : .systemGroupedBackground
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.delegate = self
    tableView.keyboardDismissMode = .interactive
    tableView.cellLayoutMarginsFollowReadableWidth = true
    tableView.register(FormStandardCell.self, forCellReuseIdentifier: FormStandardCell.reuseIdentifier)
    tableView.register(FormTextFieldCell.self, forCellReuseIdentifier: FormTextFieldCell.reuseIdentifier)
    tableView.register(FormNoteCell.self, forCellReuseIdentifier: FormNoteCell.reuseIdentifier)
    registerCells(in: tableView)
    view.addSubview(tableView)
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    dataSource = FormDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
      self?.cell(for: id, at: indexPath, in: tableView) ?? UITableViewCell()
    }
    dataSource.owner = self
    dataSource.defaultRowAnimation = .fade

    // First render is synchronous so the list is filled before the first frame.
    renderToken = CompatObservation.observe { [weak self] in
      self?.render()
    }
  }

  /// Re-runs `makeSections()` on the next main-queue turn.
  public func setNeedsFormUpdate() {
    guard isViewLoaded, !updateScheduled else { return }
    updateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.updateScheduled = false
      self.render()
    }
  }

  public func row(for id: FormItemID) -> FormRow? { rowsByID[id] }

  public func indexPath(forRow rowID: String, inSection sectionID: String) -> IndexPath? {
    dataSource.indexPath(for: FormItemID(section: sectionID, row: rowID))
  }

  // MARK: Rendering

  private func render() {
    let built = makeSections()
    let (plan, sanitized) = FormDiff.plan(old: sections, new: built)
    sections = sanitized
    rowsByID = [:]
    for section in sanitized {
      for row in section.rows {
        rowsByID[FormItemID(section: section.id, row: row.id)] = row
      }
    }

    var snapshot = NSDiffableDataSourceSnapshot<String, FormItemID>()
    snapshot.appendSections(plan.sections)
    for section in plan.sections {
      snapshot.appendItems(plan.items[section] ?? [], toSection: section)
    }
    let surviving = Set(snapshot.itemIdentifiers)
    let reconfigure = plan.reconfigure.filter { surviving.contains($0) }
    if !reconfigure.isEmpty {
      snapshot.reconfigureItems(reconfigure)
    }
    let animate = hasRendered && view.window != nil && !UIAccessibility.isReduceMotionEnabled
    dataSource.apply(snapshot, animatingDifferences: animate)
    if !plan.reloadSections.isEmpty {
      // Header/footer text changed: refresh the visible ones in place.
      for sectionID in plan.reloadSections {
        guard let index = plan.sections.firstIndex(of: sectionID) else { continue }
        UIView.performWithoutAnimation {
          tableView.headerView(forSection: index)?.textLabel?.text = sections[index].header?.uppercased()
          tableView.footerView(forSection: index)?.textLabel?.text = sections[index].footer
          tableView.beginUpdates()
          tableView.endUpdates()
        }
      }
    }
    hasRendered = true
  }

  private func cell(for id: FormItemID, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
    guard let row = rowsByID[id] else { return UITableViewCell() }
    switch row.style {
    case .standard, .button:
      let cell = tableView.dequeueReusableCell(withIdentifier: FormStandardCell.reuseIdentifier, for: indexPath)
      (cell as? FormStandardCell)?.apply(row)
      return cell
    case .textField:
      let cell = tableView.dequeueReusableCell(withIdentifier: FormTextFieldCell.reuseIdentifier, for: indexPath)
      (cell as? FormTextFieldCell)?.apply(row)
      return cell
    case .note:
      let cell = tableView.dequeueReusableCell(withIdentifier: FormNoteCell.reuseIdentifier, for: indexPath)
      (cell as? FormNoteCell)?.apply(row)
      return cell
    case let .custom(reuseIdentifier):
      let cell = tableView.dequeueReusableCell(withIdentifier: reuseIdentifier, for: indexPath)
      cell.selectionStyle = row.isSelectable ? .default : .none
      row.configureCell?(cell)
      return cell
    }
  }

  fileprivate func titleForHeader(in section: Int) -> String? {
    sections.indices.contains(section) ? sections[section].header : nil
  }

  fileprivate func titleForFooter(in section: Int) -> String? {
    sections.indices.contains(section) ? sections[section].footer : nil
  }

  fileprivate func canEdit(_ indexPath: IndexPath) -> Bool {
    rowAt(indexPath)?.onDelete != nil
  }

  fileprivate func commitDelete(_ indexPath: IndexPath) {
    rowAt(indexPath)?.onDelete?()
  }

  private func rowAt(_ indexPath: IndexPath) -> FormRow? {
    dataSource.itemIdentifier(for: indexPath).flatMap { rowsByID[$0] }
  }

  // MARK: UITableViewDelegate

  open func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    rowAt(indexPath)?.isSelectable ?? false
  }

  open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let row = rowAt(indexPath), row.isSelectable else { return }
    row.onSelect?()
  }

  open func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard let row = rowAt(indexPath), let onDelete = row.onDelete else { return nil }
    let action = UIContextualAction(style: .destructive, title: row.deleteTitle ?? "Delete") { _, _, done in
      onDelete()
      done(true)
    }
    return UISwipeActionsConfiguration(actions: [action])
  }

  open func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let build = rowAt(indexPath)?.contextMenu else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in build() }
  }
}

/// Diffable data source that also serves section titles and swipe-to-delete.
private final class FormDataSource: UITableViewDiffableDataSource<String, FormItemID> {
  weak var owner: FormViewController?

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    owner?.titleForHeader(in: section)
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    owner?.titleForFooter(in: section)
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    owner?.canEdit(indexPath) ?? false
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    if editingStyle == .delete { owner?.commitDelete(indexPath) }
  }
}

// MARK: - Cells

/// Title / subtitle / value row on `UIListContentConfiguration`, with Settings-style icons.
public final class FormStandardCell: UITableViewCell {
  public static let reuseIdentifier = "FormStandardCell"

  private var onToggle: (@MainActor (Bool) -> Void)?
  private lazy var toggle: UISwitch = {
    let toggle = UISwitch()
    toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    return toggle
  }()

  private lazy var spinner = UIActivityIndicatorView(style: .medium)

  public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: .default, reuseIdentifier: reuseIdentifier)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ row: FormRow) {
    var content: UIListContentConfiguration
    switch row.style {
    case let .button(role):
      content = .cell()
      content.text = row.title
      content.textProperties.alignment = .center
      content.textProperties.color = Self.color(for: role)
    default:
      content = row.value == nil || row.subtitle != nil ? .subtitleCell() : .valueCell()
      if row.value != nil, row.subtitle != nil {
        content = .subtitleCell()
      }
      content.text = row.title
      content.secondaryText = row.subtitle ?? row.value
      content.textProperties.color = Self.color(for: row.role)
      if row.subtitle != nil {
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.textToSecondaryTextVerticalPadding = 2
      }
      if let icon = row.icon {
        content.image = FormIconRenderer.image(for: icon)
        if icon.background == nil {
          content.imageProperties.tintColor = icon.tint ?? tintColor
        }
        content.imageProperties.reservedLayoutSize = CGSize(width: 29, height: 29)
      }
    }
    if !row.isEnabled {
      content.textProperties.color = .tertiaryLabel
    }
    contentConfiguration = content

    // Trailing value with a subtitle: show the value as a detail label.
    if row.value != nil, row.subtitle != nil {
      let label = UILabel()
      label.text = row.value
      label.textColor = .secondaryLabel
      label.font = .preferredFont(forTextStyle: .body)
      label.sizeToFit()
      accessoryView = label
    } else {
      accessoryView = nil
    }

    accessoryType = .none
    onToggle = nil
    switch row.accessory {
    case .none:
      break
    case .disclosure:
      accessoryType = .disclosureIndicator
    case .checkmark:
      accessoryType = .checkmark
    case .detailButton:
      accessoryType = .detailButton
    case let .toggle(isOn):
      toggle.isOn = isOn
      toggle.isEnabled = row.isEnabled
      onToggle = row.onToggle
      accessoryView = toggle
    case .activity:
      spinner.startAnimating()
      accessoryView = spinner
    }
    selectionStyle = row.isSelectable ? .default : .none
    accessibilityTraits = row.isSelectable ? .button : .none
  }

  @objc private func toggleChanged() {
    CompatHaptics.selection()
    onToggle?(toggle.isOn)
  }

  static func color(for role: FormRole) -> UIColor {
    switch role {
    case .normal: .label
    case .destructive: .systemRed
    case .accent: .tintColor
    }
  }
}

/// Settings-style icon tile (white symbol on a rounded colored square).
@MainActor
enum FormIconRenderer {
  private static var cache: [FormIcon: UIImage] = [:]

  static func image(for icon: FormIcon) -> UIImage? {
    guard let background = icon.background else {
      return UIImage(systemName: icon.systemName)
    }
    if let cached = cache[icon] { return cached }
    let size = CGSize(width: 29, height: 29)
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let symbol = UIImage(systemName: icon.systemName, withConfiguration: symbolConfig)?
      .withTintColor(icon.tint ?? .white, renderingMode: .alwaysOriginal)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { _ in
      let rect = CGRect(origin: .zero, size: size)
      background.setFill()
      UIBezierPath(roundedRect: rect, cornerRadius: 7).fill()
      if let symbol {
        let symbolSize = symbol.size
        symbol.draw(in: CGRect(
          x: (size.width - symbolSize.width) / 2,
          y: (size.height - symbolSize.height) / 2,
          width: symbolSize.width,
          height: symbolSize.height
        ))
      }
    }
    // Dynamic backgrounds re-render per appearance through the cache key (resolved colors).
    cache[icon] = image
    return image
  }
}

public final class FormTextFieldCell: UITableViewCell, UITextFieldDelegate {
  public static let reuseIdentifier = "FormTextFieldCell"

  public let textField = UITextField()
  private var onChange: (@MainActor (String) -> Void)?

  public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.font = .preferredFont(forTextStyle: .body)
    textField.adjustsFontForContentSizeCategory = true
    textField.clearButtonMode = .whileEditing
    textField.delegate = self
    textField.addTarget(self, action: #selector(changed), for: .editingChanged)
    contentView.addSubview(textField)
    NSLayoutConstraint.activate([
      textField.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      textField.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      textField.topAnchor.constraint(equalTo: contentView.topAnchor),
      textField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ row: FormRow) {
    guard case let .textField(placeholder, secure) = row.style else { return }
    textField.placeholder = placeholder
    textField.isSecureTextEntry = secure
    textField.keyboardType = row.keyboardType
    textField.textContentType = row.textContentType
    textField.isEnabled = row.isEnabled
    // Never stomp on what the person is typing.
    if !textField.isFirstResponder || textField.text != row.title {
      if !textField.isFirstResponder { textField.text = row.title }
    }
    onChange = row.onTextChange
  }

  @objc private func changed() {
    onChange?(textField.text ?? "")
  }

  public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }
}

public final class FormNoteCell: UITableViewCell {
  public static let reuseIdentifier = "FormNoteCell"

  func apply(_ row: FormRow) {
    var content = UIListContentConfiguration.cell()
    content.text = row.title
    content.textProperties.color = .secondaryLabel
    content.textProperties.font = .preferredFont(forTextStyle: .footnote)
    contentConfiguration = content
    selectionStyle = .none
  }
}
#endif
