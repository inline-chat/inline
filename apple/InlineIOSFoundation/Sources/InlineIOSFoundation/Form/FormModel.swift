import Foundation
#if canImport(UIKit)
import UIKit
#endif

// Declarative description of a list/settings screen, rendered by `FormViewController`.
//
// Screens rebuild the whole `[FormSection]` from current state whenever it changes; the
// controller diffs by stable ids, animates inserts/removals/moves and reconfigures rows whose
// visible content changed. Same model as Telegram's ItemListController.

public struct FormSection: Identifiable {
  public var id: String
  public var header: String?
  public var footer: String?
  public var rows: [FormRow]

  public init(_ id: String, header: String? = nil, footer: String? = nil, rows: [FormRow]) {
    self.id = id
    self.header = header
    self.footer = footer
    self.rows = rows
  }

  public init(
    _ id: String,
    header: String? = nil,
    footer: String? = nil,
    @FormRowsBuilder rows: () -> [FormRow]
  ) {
    self.init(id, header: header, footer: footer, rows: rows())
  }
}

public enum FormRole: Hashable, Sendable {
  case normal
  case destructive
  case accent
}

/// Leading icon. Settings-style rounded tile when `background` is set, plain symbol otherwise.
public struct FormIcon: Hashable, @unchecked Sendable {
  public var systemName: String
  #if canImport(UIKit)
  public var tint: UIColor?
  public var background: UIColor?

  public init(systemName: String, tint: UIColor? = nil, background: UIColor? = nil) {
    self.systemName = systemName
    self.tint = tint
    self.background = background
  }

  public static func == (lhs: FormIcon, rhs: FormIcon) -> Bool {
    lhs.systemName == rhs.systemName
      && ColorKey(lhs.tint) == ColorKey(rhs.tint)
      && ColorKey(lhs.background) == ColorKey(rhs.background)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(systemName)
    hasher.combine(ColorKey(tint))
    hasher.combine(ColorKey(background))
  }
  #else
  public init(systemName: String) {
    self.systemName = systemName
  }
  #endif
}

#if canImport(UIKit)
/// Value identity for a (possibly dynamic) color: its light and dark resolved RGBA.
struct ColorKey: Hashable {
  var light: [CGFloat]
  var dark: [CGFloat]

  init?(_ color: UIColor?) {
    guard let color else { return nil }
    light = Self.components(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    dark = Self.components(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
  }

  private static func components(_ color: UIColor) -> [CGFloat] {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return [r, g, b, a].map { ($0 * 1000).rounded() / 1000 }
  }
}
#endif

public struct FormRow: Identifiable {
  public enum Accessory: Hashable, Sendable {
    case none
    case disclosure
    case checkmark
    case toggle(isOn: Bool)
    case activity
    case detailButton
  }

  public enum Style: Hashable, Sendable {
    /// Title, optional subtitle and trailing value.
    case standard
    /// Centered button text.
    case button(FormRole)
    /// Single line text input.
    case textField(placeholder: String, secure: Bool)
    /// Multi-line note text, not selectable.
    case note
    /// Caller-built cell.
    case custom(reuseIdentifier: String)
  }

  public var id: String
  public var style: Style
  public var title: String
  public var subtitle: String?
  public var value: String?
  public var icon: FormIcon?
  public var accessory: Accessory
  public var role: FormRole
  public var isEnabled: Bool
  /// Extra content that should cause a reconfigure when it changes (for custom rows).
  public var contentKey: AnyHashable?

  public var onSelect: (@MainActor () -> Void)?
  public var onToggle: (@MainActor (Bool) -> Void)?
  public var onTextChange: (@MainActor (String) -> Void)?
  public var onDelete: (@MainActor () -> Void)?
  public var deleteTitle: String?
  #if canImport(UIKit)
  public var configureCell: (@MainActor (UITableViewCell) -> Void)?
  public var contextMenu: (@MainActor () -> UIMenu?)?
  public var keyboardType: UIKeyboardType = .default
  public var textContentType: UITextContentType?
  #endif

  public init(
    _ id: String,
    style: Style = .standard,
    title: String,
    subtitle: String? = nil,
    value: String? = nil,
    icon: FormIcon? = nil,
    accessory: Accessory = .none,
    role: FormRole = .normal,
    isEnabled: Bool = true,
    contentKey: AnyHashable? = nil
  ) {
    self.id = id
    self.style = style
    self.title = title
    self.subtitle = subtitle
    self.value = value
    self.icon = icon
    self.accessory = accessory
    self.role = role
    self.isEnabled = isEnabled
    self.contentKey = contentKey
  }

  /// Hash of everything that is drawn. Rows with equal ids and different content hashes are
  /// reconfigured in place.
  public var contentHash: Int {
    var hasher = Hasher()
    hasher.combine(style)
    hasher.combine(title)
    hasher.combine(subtitle)
    hasher.combine(value)
    hasher.combine(icon)
    hasher.combine(accessory)
    hasher.combine(role)
    hasher.combine(isEnabled)
    hasher.combine(contentKey)
    hasher.combine(onSelect == nil)
    return hasher.finalize()
  }

  public var isSelectable: Bool {
    guard isEnabled else { return false }
    switch style {
    case .textField, .note: return false
    default: break
    }
    if case .toggle = accessory { return false }
    return onSelect != nil
  }
}

// MARK: - Row factories

extension FormRow {
  public static func navigation(
    _ id: String,
    _ title: String,
    subtitle: String? = nil,
    value: String? = nil,
    icon: FormIcon? = nil,
    isEnabled: Bool = true,
    action: @escaping @MainActor () -> Void
  ) -> FormRow {
    var row = FormRow(
      id, title: title, subtitle: subtitle, value: value, icon: icon,
      accessory: .disclosure, isEnabled: isEnabled
    )
    row.onSelect = action
    return row
  }

  public static func toggle(
    _ id: String,
    _ title: String,
    subtitle: String? = nil,
    icon: FormIcon? = nil,
    isOn: Bool,
    isEnabled: Bool = true,
    onChange: @escaping @MainActor (Bool) -> Void
  ) -> FormRow {
    var row = FormRow(
      id, title: title, subtitle: subtitle, icon: icon,
      accessory: .toggle(isOn: isOn), isEnabled: isEnabled
    )
    row.onToggle = onChange
    return row
  }

  public static func value(
    _ id: String,
    _ title: String,
    value: String?,
    subtitle: String? = nil,
    icon: FormIcon? = nil
  ) -> FormRow {
    FormRow(id, title: title, subtitle: subtitle, value: value, icon: icon)
  }

  public static func action(
    _ id: String,
    _ title: String,
    subtitle: String? = nil,
    value: String? = nil,
    icon: FormIcon? = nil,
    role: FormRole = .accent,
    isEnabled: Bool = true,
    isLoading: Bool = false,
    action: @escaping @MainActor () -> Void
  ) -> FormRow {
    var row = FormRow(
      id, title: title, subtitle: subtitle, value: value, icon: icon,
      accessory: isLoading ? .activity : .none, role: role, isEnabled: isEnabled && !isLoading
    )
    row.onSelect = action
    return row
  }

  public static func button(
    _ id: String,
    _ title: String,
    role: FormRole = .accent,
    isEnabled: Bool = true,
    isLoading: Bool = false,
    action: @escaping @MainActor () -> Void
  ) -> FormRow {
    var row = FormRow(
      id, style: .button(role), title: title,
      accessory: isLoading ? .activity : .none, role: role, isEnabled: isEnabled && !isLoading
    )
    row.onSelect = action
    return row
  }

  public static func check(
    _ id: String,
    _ title: String,
    subtitle: String? = nil,
    icon: FormIcon? = nil,
    isSelected: Bool,
    isEnabled: Bool = true,
    action: @escaping @MainActor () -> Void
  ) -> FormRow {
    var row = FormRow(
      id, title: title, subtitle: subtitle, icon: icon,
      accessory: isSelected ? .checkmark : .none, isEnabled: isEnabled
    )
    row.onSelect = action
    return row
  }

  public static func textField(
    _ id: String,
    placeholder: String,
    text: String,
    secure: Bool = false,
    onChange: @escaping @MainActor (String) -> Void
  ) -> FormRow {
    var row = FormRow(id, style: .textField(placeholder: placeholder, secure: secure), title: text)
    row.onTextChange = onChange
    return row
  }

  public static func note(_ id: String, _ text: String) -> FormRow {
    FormRow(id, style: .note, title: text)
  }

  #if canImport(UIKit)
  /// Row rendered by a caller-registered cell class. `contentKey` must change whenever what
  /// `configure` draws changes.
  public static func custom(
    _ id: String,
    reuseIdentifier: String,
    contentKey: AnyHashable,
    isEnabled: Bool = true,
    onSelect: (@MainActor () -> Void)? = nil,
    configure: @escaping @MainActor (UITableViewCell) -> Void
  ) -> FormRow {
    var row = FormRow(
      id, style: .custom(reuseIdentifier: reuseIdentifier), title: "",
      isEnabled: isEnabled, contentKey: contentKey
    )
    row.onSelect = onSelect
    row.configureCell = configure
    return row
  }
  #endif

  // Modifiers

  public func deletable(_ title: String? = nil, _ action: @escaping @MainActor () -> Void) -> FormRow {
    var copy = self
    copy.onDelete = action
    copy.deleteTitle = title
    return copy
  }

  #if canImport(UIKit)
  public func menu(_ build: @escaping @MainActor () -> UIMenu?) -> FormRow {
    var copy = self
    copy.contextMenu = build
    return copy
  }

  public func keyboard(_ type: UIKeyboardType, contentType: UITextContentType? = nil) -> FormRow {
    var copy = self
    copy.keyboardType = type
    copy.textContentType = contentType
    return copy
  }
  #endif
}

// MARK: - Builders

@resultBuilder
public enum FormRowsBuilder {
  public static func buildExpression(_ row: FormRow) -> [FormRow] { [row] }
  public static func buildExpression(_ rows: [FormRow]) -> [FormRow] { rows }
  public static func buildBlock(_ parts: [FormRow]...) -> [FormRow] { parts.flatMap { $0 } }
  public static func buildOptional(_ rows: [FormRow]?) -> [FormRow] { rows ?? [] }
  public static func buildEither(first rows: [FormRow]) -> [FormRow] { rows }
  public static func buildEither(second rows: [FormRow]) -> [FormRow] { rows }
  public static func buildArray(_ parts: [[FormRow]]) -> [FormRow] { parts.flatMap { $0 } }
  public static func buildLimitedAvailability(_ rows: [FormRow]) -> [FormRow] { rows }
}

@resultBuilder
public enum FormSectionsBuilder {
  public static func buildExpression(_ section: FormSection) -> [FormSection] { [section] }
  public static func buildExpression(_ sections: [FormSection]) -> [FormSection] { sections }
  public static func buildBlock(_ parts: [FormSection]...) -> [FormSection] { parts.flatMap { $0 } }
  public static func buildOptional(_ sections: [FormSection]?) -> [FormSection] { sections ?? [] }
  public static func buildEither(first sections: [FormSection]) -> [FormSection] { sections }
  public static func buildEither(second sections: [FormSection]) -> [FormSection] { sections }
  public static func buildArray(_ parts: [[FormSection]]) -> [FormSection] { parts.flatMap { $0 } }
  public static func buildLimitedAvailability(_ sections: [FormSection]) -> [FormSection] { sections }
}

// MARK: - Diff plan

/// Stable id of a row inside a form.
public struct FormItemID: Hashable, Sendable, CustomStringConvertible {
  public var section: String
  public var row: String

  public init(section: String, row: String) {
    self.section = section
    self.row = row
  }

  public var description: String { "\(section)/\(row)" }
}

public struct FormPlan: Equatable, Sendable {
  public var sections: [String]
  public var items: [String: [FormItemID]]
  /// Rows present before and after whose drawn content changed.
  public var reconfigure: [FormItemID]
  /// Sections whose header or footer changed (reloaded as a whole).
  public var reloadSections: [String]
}

public enum FormDiff {
  /// Validates ids and computes what to apply. Duplicate section or row ids are dropped
  /// (first wins) so a buggy screen cannot crash the diffable data source.
  public static func plan(old: [FormSection], new: [FormSection]) -> (plan: FormPlan, sanitized: [FormSection]) {
    var seenSections = Set<String>()
    var sanitized: [FormSection] = []
    for section in new where seenSections.insert(section.id).inserted {
      var seenRows = Set<String>()
      var copy = section
      copy.rows = section.rows.filter { seenRows.insert($0.id).inserted }
      sanitized.append(copy)
    }

    var oldHashes: [FormItemID: Int] = [:]
    var oldSections: [String: FormSection] = [:]
    for section in old {
      oldSections[section.id] = section
      for row in section.rows {
        oldHashes[FormItemID(section: section.id, row: row.id)] = row.contentHash
      }
    }

    var items: [String: [FormItemID]] = [:]
    var reconfigure: [FormItemID] = []
    var reloadSections: [String] = []
    for section in sanitized {
      let ids = section.rows.map { FormItemID(section: section.id, row: $0.id) }
      items[section.id] = ids
      for (id, row) in zip(ids, section.rows) {
        if let oldHash = oldHashes[id], oldHash != row.contentHash {
          reconfigure.append(id)
        }
      }
      if let previous = oldSections[section.id],
         previous.header != section.header || previous.footer != section.footer
      {
        reloadSections.append(section.id)
      }
    }

    return (
      FormPlan(
        sections: sanitized.map(\.id),
        items: items,
        reconfigure: reconfigure,
        reloadSections: reloadSections
      ),
      sanitized
    )
  }
}
