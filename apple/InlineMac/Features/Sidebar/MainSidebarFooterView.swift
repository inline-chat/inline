import AppKit
import SwiftUI

enum MainSidebarFooterMetrics {
  static let buttonSize: CGFloat = 26
  static let cornerRadius: CGFloat = 8
  static let verticalPadding: CGFloat = 6

  static let iconPointSize: CGFloat = 13
  static let iconWeight: Font.Weight = .medium

  static let height: CGFloat = buttonSize + (verticalPadding * 2)
  static let iconFont: Font = .system(size: iconPointSize, weight: iconWeight)

  static func backgroundColor(
    colorScheme: ColorScheme,
    isHovering: Bool,
    isPressed: Bool
  ) -> Color {
    if isPressed {
      return colorScheme == .dark
        ? Color.white.opacity(0.24)
        : Color.black.opacity(0.10)
    }

    if isHovering {
      return colorScheme == .dark
        ? Color.white.opacity(0.18)
        : Color.black.opacity(0.06)
    }

    return .clear
  }
}

struct MainSidebarFooterView: View {
  let isArchiveActive: Bool
  let isPreviewEnabled: Bool
  let horizontalPadding: CGFloat

  let onToggleArchive: () -> Void
  let onSearch: () -> Void
  let onNewSpace: () -> Void
  let onInvite: () -> Void
  let onNewThread: () -> Void
  let onSetCompact: () -> Void
  let onSetPreview: () -> Void

  private var iconTint: Color {
    Color(nsColor: .tertiaryLabelColor)
  }

  var body: some View {
    HStack(spacing: 0) {
      slot {
        FooterIconButton(
          symbolName: isArchiveActive ? "archivebox.fill" : "archivebox",
          accessibilityLabel: "Archive",
          tint: iconTint,
          action: onToggleArchive
        )
      }

      slot {
        FooterIconButton(
          symbolName: "magnifyingglass",
          accessibilityLabel: "Search",
          tint: iconTint,
          action: onSearch
        )
      }

      slot {
        FooterIconMenu(
          symbolName: "plus",
          accessibilityLabel: "New",
          tint: iconTint
        ) {
          Button(action: onNewSpace) {
            Label("New Space", systemImage: "plus")
          }
          Button(action: onInvite) {
            Label("Invite", systemImage: "person.badge.plus")
          }
          Button(action: onNewThread) {
            Label("New Thread", systemImage: "bubble.left.and.bubble.right")
          }
        }
      }

      slot {
        FooterDecoratedControl(accessibilityLabel: "View options") {
          SidebarViewOptionsButton(
            isPreviewEnabled: isPreviewEnabled,
            onSetCompact: onSetCompact,
            onSetPreview: onSetPreview
          )
        }
      }

      slot {
        FooterDecoratedControl(accessibilityLabel: "Notifications") {
          NotificationSettingsButton(style: .sidebarFooter)
        }
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, MainSidebarFooterMetrics.verticalPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  @ViewBuilder
  private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

private struct FooterIconButton: View {
  let symbolName: String
  let accessibilityLabel: String
  let tint: Color
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbolName)
        .font(MainSidebarFooterMetrics.iconFont)
        .foregroundStyle(tint)
        .frame(
          width: MainSidebarFooterMetrics.buttonSize,
          height: MainSidebarFooterMetrics.buttonSize,
          alignment: .center
        )
        .contentShape(
          RoundedRectangle(
            cornerRadius: MainSidebarFooterMetrics.cornerRadius,
            style: .continuous
          )
        )
    }
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
    .onHover { isHovering = $0 }
  }
}

private struct FooterIconMenu<MenuContent: View>: View {
  let symbolName: String
  let accessibilityLabel: String
  let tint: Color
  @ViewBuilder let content: () -> MenuContent

  @State private var isHovering = false

  var body: some View {
    Menu(content: content) {
      Image(systemName: symbolName)
        .font(MainSidebarFooterMetrics.iconFont)
        .foregroundStyle(tint)
        .frame(
          width: MainSidebarFooterMetrics.buttonSize,
          height: MainSidebarFooterMetrics.buttonSize,
          alignment: .center
        )
        .contentShape(
          RoundedRectangle(
            cornerRadius: MainSidebarFooterMetrics.cornerRadius,
            style: .continuous
          )
        )
    }
    .menuStyle(.button)
    .buttonStyle(SidebarFooterButtonStyle(isHovering: isHovering))
    .menuIndicator(.hidden)
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
    .onHover { isHovering = $0 }
  }
}

private struct FooterDecoratedControl<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme

  let accessibilityLabel: String
  @ViewBuilder let content: () -> Content

  @State private var isHovering = false
  @GestureState private var isPressed = false

  var body: some View {
    content()
      .frame(
        width: MainSidebarFooterMetrics.buttonSize,
        height: MainSidebarFooterMetrics.buttonSize,
        alignment: .center
      )
      .background(
        RoundedRectangle(
          cornerRadius: MainSidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
        .fill(
          MainSidebarFooterMetrics.backgroundColor(
            colorScheme: colorScheme,
            isHovering: isHovering,
            isPressed: isPressed
          )
        )
      )
      .contentShape(
        RoundedRectangle(
          cornerRadius: MainSidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
      )
      .accessibilityLabel(accessibilityLabel)
      .help(accessibilityLabel)
      .onHover { isHovering = $0 }
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .updating($isPressed) { _, state, _ in
            state = true
          }
      )
  }
}

private struct SidebarFooterButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  let isHovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(
          cornerRadius: MainSidebarFooterMetrics.cornerRadius,
          style: .continuous
        )
        .fill(
          MainSidebarFooterMetrics.backgroundColor(
            colorScheme: colorScheme,
            isHovering: isHovering,
            isPressed: configuration.isPressed
          )
        )
      )
  }
}

private enum SidebarViewOptionSelection: String, CaseIterable {
  case compact
  case preview

  var title: String {
    switch self {
      case .compact:
        "Compact"
      case .preview:
        "Show previews"
    }
  }

  var menuDescription: String {
    switch self {
      case .compact:
        "Only show chat titles in the sidebar"
      case .preview:
        "Show a message preview under each chat title"
    }
  }

  var iconName: String {
    switch self {
      case .compact:
        "rectangle.compress.vertical"
      case .preview:
        "rectangle.expand.vertical"
    }
  }
}

private struct SidebarViewOptionsButton: NSViewRepresentable {
  let isPreviewEnabled: Bool
  let onSetCompact: () -> Void
  let onSetPreview: () -> Void

  func makeNSView(context: Context) -> SidebarViewOptionsMenuButton {
    let button = SidebarViewOptionsMenuButton()
    button.onSelect = { selection in
      switch selection {
        case .compact:
          onSetCompact()
        case .preview:
          onSetPreview()
      }
    }
    button.updateSelection(isPreviewEnabled: isPreviewEnabled)
    return button
  }

  func updateNSView(_ nsView: SidebarViewOptionsMenuButton, context: Context) {
    nsView.onSelect = { selection in
      switch selection {
        case .compact:
          onSetCompact()
        case .preview:
          onSetPreview()
      }
    }
    nsView.updateSelection(isPreviewEnabled: isPreviewEnabled)
  }
}

@MainActor
private final class SidebarViewOptionsMenuButton: NSButton {
  var onSelect: ((SidebarViewOptionSelection) -> Void)?

  private var currentSelection: SidebarViewOptionSelection = .compact {
    didSet {
      guard oldValue != currentSelection else { return }
      updateMenuSelectionState()
    }
  }

  private lazy var optionsMenu = buildMenu()

  init() {
    super.init(frame: .zero)
    configure()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateSelection(isPreviewEnabled: Bool) {
    currentSelection = isPreviewEnabled ? .preview : .compact
  }

  private func configure() {
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    setButtonType(.momentaryChange)
    contentTintColor = .tertiaryLabelColor
    imageScaling = .scaleProportionallyDown
    target = self
    action = #selector(showMenu)
    toolTip = "View options"

    widthAnchor.constraint(equalToConstant: MainSidebarFooterMetrics.buttonSize).isActive = true
    heightAnchor.constraint(equalToConstant: MainSidebarFooterMetrics.buttonSize).isActive = true

    if let image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "View options")
    {
      let configuredImage = image.withSymbolConfiguration(NSImage.SymbolConfiguration(
        pointSize: MainSidebarFooterMetrics.iconPointSize,
        weight: .medium,
        scale: .medium
      ))
      self.image = configuredImage
    }

    updateAlpha()
    updateMenuSelectionState()
  }

  @objc
  private func showMenu() {
    updateMenuSelectionState()
    optionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
  }

  @objc
  private func handleMenuSelection(_ sender: NSMenuItem) {
    guard
      let rawValue = sender.representedObject as? String,
      let selection = SidebarViewOptionSelection(rawValue: rawValue)
    else {
      return
    }
    guard selection != currentSelection else { return }
    currentSelection = selection
    onSelect?(selection)
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    for option in SidebarViewOptionSelection.allCases {
      let item = NSMenuItem(title: "", action: #selector(handleMenuSelection(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = option.rawValue
      item.image = menuItemImage(for: option)
      item.attributedTitle = menuItemTitle(for: option)
      menu.addItem(item)
    }
    return menu
  }

  private func updateMenuSelectionState() {
    for item in optionsMenu.items {
      guard
        let rawValue = item.representedObject as? String,
        let option = SidebarViewOptionSelection(rawValue: rawValue)
      else {
        continue
      }
      item.state = option == currentSelection ? .on : .off
    }
  }

  private func menuItemImage(for option: SidebarViewOptionSelection) -> NSImage? {
    guard let image = NSImage(systemSymbolName: option.iconName, accessibilityDescription: option.title) else {
      return nil
    }
    return image.withSymbolConfiguration(.init(pointSize: 13, weight: .regular, scale: .medium))
  }

  private func menuItemTitle(for option: SidebarViewOptionSelection) -> NSAttributedString {
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.menuFont(ofSize: 13),
      .foregroundColor: NSColor.labelColor,
    ]
    let descriptionAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]

    let attributed = NSMutableAttributedString(string: option.title, attributes: titleAttributes)
    attributed.append(NSAttributedString(string: "\n"))
    attributed.append(NSAttributedString(string: option.menuDescription, attributes: descriptionAttributes))
    return attributed
  }

  override var isHighlighted: Bool {
    didSet { updateAlpha() }
  }

  override var isEnabled: Bool {
    didSet { updateAlpha() }
  }

  private func updateAlpha() {
    if isHighlighted {
      alphaValue = 0.7
    } else {
      alphaValue = isEnabled ? 1 : 0.35
    }
  }
}
