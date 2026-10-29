@testable import InlineIOS
import Testing
import UIKit

/// On-device checks for the custom message context menu: UIKit's own menu as the reference, and
/// the custom menu's states. Each state holds long enough for
/// `devicectl device capture screenshot`.
@Suite("Message context menu on device", .serialized)
@MainActor
struct MessageContextMenuDeviceTests {
  // MARK: - Native reference

  @Test("UIKit's context menu geometry on this device")
  func nativeMenuGeometry() async throws {
    let stage = try Stage(caption: "NATIVE MENU")
    defer { stage.close() }
    let source = UIView(frame: CGRect(x: 120, y: 260, width: 160, height: 44))
    source.backgroundColor = .systemBlue
    source.layer.cornerRadius = 18
    stage.root.addSubview(source)
    let provider = MenuProvider(menu: Self.chatMenu())
    let interaction = UIContextMenuInteraction(delegate: provider)
    source.addInteraction(interaction)
    let before = Set(try stage.sceneWindows().map(ObjectIdentifier.init))

    try present(interaction, at: CGPoint(x: source.bounds.midX, y: source.bounds.midY))
    defer { interaction.dismissMenu() }
    try await Task.sleep(for: .seconds(1.5))

    var report: [String] = []
    for window in try stage.sceneWindows() {
      let isNew = !before.contains(ObjectIdentifier(window))
      report.append("window \(type(of: window)) level=\(window.windowLevel.rawValue) new=\(isNew) key=\(window.isKeyWindow)")
      for root in Self.menuRoots(in: window) {
        Self.dump(root, in: window, depth: 0, into: &report)
      }
    }
    Attachment.record(report.joined(separator: "\n"), named: "native-menu-geometry.txt")
    #expect(report.contains { $0.contains("UILabel") && $0.contains("Reply in Thread") })
    try await Task.sleep(for: .seconds(5))
  }

  // MARK: - Custom menu

  @Test("The custom menu's states: short, selection, submenu, tall, keyboard")
  func customMenuStates() async throws {
    let lab = MessageContextMenuLabController()
    let stage = try Stage(root: UINavigationController(rootViewController: lab))
    defer { stage.close() }
    lab.slowDownForTesting(by: 6)
    try await Task.sleep(for: .seconds(1))
    var report: [String] = []

    // Short message, then a selection: rows that stay must be the same views, and no title
    // may show twice at once.
    let short = try #require(lab.openMenuForTesting(row: 2))
    try await Task.sleep(for: .seconds(4))
    report.append("short: " + Self.describe(short))
    let before = Dictionary(uniqueKeysWithValues: short.actionsViewForTesting.rowsForTesting.map { ($0.key, ObjectIdentifier($0)) })
    let selection = try #require(short.selectionViewForTesting)
    selection.selectForTesting(NSRange(location: 0, length: 4))
    var doubled: Set<String> = []
    var frames: [UIImage] = []
    for index in 0 ..< 24 {
      let rows = short.actionsViewForTesting.allRowsForTesting
      let visible = rows.filter { ($0.layer.presentation()?.opacity ?? Float($0.alpha)) > 0.05 && $0.window != nil }
      let titles = visible.map(\.accessibilityLabel)
      for title in titles where titles.filter({ $0 == title }).count > 1 { doubled.insert(title ?? "?") }
      if index % 4 == 0, let window = short.presentationWindow { frames.append(Self.snapshot(window)) }
      try await Task.sleep(for: .milliseconds(120))
    }
    let after = short.actionsViewForTesting.rowsForTesting
    let kept = after.filter { before[$0.key] == ObjectIdentifier($0) }.map(\.key)
    report.append("selection: rows \(after.map(\.key)); kept \(kept.count) of \(before.count); doubled \(doubled.sorted())")
    #expect(doubled.isEmpty)
    #expect(kept.count >= before.count - 1)
    Attachment.record(Array(try #require(Self.sheet(frames).pngData())), named: "selection-change.png")
    try await Task.sleep(for: .seconds(2))

    // Submenu: the new page's titles are never laid out narrower than they need.
    let actionsRow = try #require(short.actionsViewForTesting.rowsForTesting.first { $0.key.hasPrefix("menu|") })
    guard case let .submenu(submenu) = actionsRow.element else { Issue.record("no submenu"); return }
    short.actionsViewForTesting.open(submenu)
    var truncated: Set<String> = []
    frames = []
    for index in 0 ..< 24 {
      for row in short.actionsViewForTesting.rowsForTesting where row.isTitleTruncated {
        truncated.insert(row.accessibilityLabel ?? "?")
      }
      if index % 4 == 0, let window = short.presentationWindow { frames.append(Self.snapshot(window)) }
      try await Task.sleep(for: .milliseconds(120))
    }
    report.append("submenu: rows \(short.actionsViewForTesting.rowsForTesting.map(\.key)); truncated \(truncated.sorted())")
    #expect(truncated.isEmpty)
    Attachment.record(Array(try #require(Self.sheet(frames).pngData())), named: "submenu-open.png")
    try await Task.sleep(for: .seconds(2))
    short.dismiss(animated: false)
    try await Task.sleep(for: .seconds(0.5))

    // Tall message: the reaction bar stays below the top inset over the message.
    let tall = try #require(lab.openMenuForTesting(row: 3))
    try await Task.sleep(for: .seconds(4))
    let bar = tall.accessoryHostForTesting
    let safeTop = stage.window.safeAreaInsets.top
    report.append("tall: bar \(bar.frame) shadow \(bar.layer.shadowOpacity) safeTop \(safeTop) " + Self.describe(tall))
    #expect(bar.frame.minY >= safeTop && bar.frame.minY <= safeTop + 12)
    #expect(bar.layer.shadowOpacity > 0)
    tall.dismiss(animated: false)
    try await Task.sleep(for: .seconds(0.5))

    // Keyboard up: the menu puts it away while it's open and brings it back when it closes.
    #expect(lab.focusKeyboardForTesting())
    try await Task.sleep(for: .seconds(1.2))
    let keyed = try #require(lab.openMenuForTesting(row: 6))
    try await Task.sleep(for: .seconds(4))
    report.append("keyboard: focused while open \(lab.isKeyboardFocusedForTesting) menu level \(keyed.presentationWindow?.windowLevel.rawValue ?? -1)")
    #expect(!lab.isKeyboardFocusedForTesting)

    // A sheet over the menu, like the emoji picker, gets a keyboard of its own on top.
    if let scene = stage.window.windowScene, let menuWindow = keyed.presentationWindow {
      let sheetWindow = UIWindow(windowScene: scene)
      sheetWindow.windowLevel = UIWindow.Level(rawValue: menuWindow.windowLevel.rawValue + 1)
      let root = UIViewController()
      root.view.backgroundColor = .clear
      let field = UITextField(frame: CGRect(x: 20, y: 160, width: 320, height: 44))
      field.borderStyle = .roundedRect
      field.placeholder = "PICKER SEARCH"
      root.view.addSubview(field)
      sheetWindow.rootViewController = root
      sheetWindow.makeKeyAndVisible()
      #expect(field.becomeFirstResponder())
      try await Task.sleep(for: .seconds(1.5))
      let levels = try stage.sceneWindows().filter { !$0.isHidden }.map { "\(type(of: $0))@\($0.windowLevel.rawValue)" }
      report.append("sheet over menu: " + levels.joined(separator: ", "))
      try await Task.sleep(for: .seconds(3))
      field.resignFirstResponder()
      sheetWindow.isHidden = true
      stage.window.makeKey()
    }
    keyed.dismiss(animated: false)
    report.append("keyboard after close: focused \(lab.isKeyboardFocusedForTesting)")
    #expect(lab.isKeyboardFocusedForTesting)
    Attachment.record(report.joined(separator: "\n"), named: "custom-states.txt")
  }

  static func describe(_ menu: MessageContextMenuController) -> String {
    let actions = menu.actionsViewForTesting
    return "menu \(actions.frame) rows \(actions.rowsForTesting.count) scroll \(menu.scrollViewForTesting.contentOffset.y)/\(menu.scrollViewForTesting.contentSize.height)"
  }

  static func snapshot(_ window: UIWindow) -> UIImage {
    UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
    }
  }

  /// Frames side by side at a third of their size.
  static func sheet(_ images: [UIImage]) -> UIImage {
    guard let first = images.first else { return UIImage() }
    let size = CGSize(width: first.size.width / 3, height: first.size.height / 3)
    return UIGraphicsImageRenderer(size: CGSize(width: size.width * CGFloat(images.count), height: size.height)).image { _ in
      for (index, image) in images.enumerated() {
        image.draw(in: CGRect(origin: CGPoint(x: size.width * CGFloat(index), y: 0), size: size))
      }
    }
  }

  // MARK: - Helpers

  /// The menu the chat builds, with the same sections, submenu and attributes.
  static func chatMenu() -> UIMenu {
    func action(_ title: String, _ image: String, attributes: UIMenuElement.Attributes = []) -> UIAction {
      UIAction(title: title, image: UIImage(systemName: image), attributes: attributes) { _ in }
    }
    return UIMenu(children: [
      UIMenu(options: .displayInline, children: [
        action("Copy", "square.on.square"),
        action("Reply", "arrowshape.turn.up.left"),
        action("Reply in Thread", "arrowshape.turn.up.left.circle"),
        action("Forward", "arrowshape.turn.up.right"),
        action("Edit", "bubble.and.pencil"),
        action("Pin", "pin"),
      ]),
      UIMenu(title: "Actions", image: UIImage(systemName: "ellipsis.circle"), children: [
        action("Create Notion Task", "checklist"),
        action("Create Linear Issue", "plus.square.dashed"),
      ]),
      UIMenu(options: .displayInline, children: [action("Delete", "trash", attributes: .destructive)]),
    ])
  }

  private func present(_ interaction: UIContextMenuInteraction, at point: CGPoint) throws {
    let selector = NSSelectorFromString("_presentMenuAtLocation:")
    let method = try #require(class_getInstanceMethod(type(of: interaction), selector))
    typealias PresentMenu = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    unsafeBitCast(method_getImplementation(method), to: PresentMenu.self)(interaction, selector, point)
  }

  /// Top-most views whose class names mark them as part of the presented menu.
  static func menuRoots(in window: UIWindow) -> [UIView] {
    var roots: [UIView] = []
    func walk(_ view: UIView) {
      if NSStringFromClass(type(of: view)).contains("ContextMenu") {
        roots.append(view)
        return
      }
      view.subviews.forEach(walk)
    }
    walk(window)
    return roots
  }

  static func dump(_ view: UIView, in window: UIWindow, depth: Int, into report: inout [String]) {
    guard depth < 40, report.count < 1_500 else { return }
    let frame = view.convert(view.bounds, to: window)
    var line = String(repeating: "  ", count: depth)
      + "\(type(of: view)) frame=(\(r(frame.minX)),\(r(frame.minY)),\(r(frame.width)),\(r(frame.height)))"
    if view.isHidden { line += " hidden" }
    if view.alpha < 1 { line += " alpha=\(r(view.alpha))" }
    if view.layer.cornerRadius > 0 { line += " radius=\(r(view.layer.cornerRadius)) curve=\(view.layer.cornerCurve.rawValue)" }
    if view.clipsToBounds { line += " clips" }
    if let color = view.backgroundColor, color != .clear { line += " bg=\(color.resolvedColor(with: view.traitCollection))" }
    if let label = view as? UILabel {
      line += " text=\"\(label.text ?? "")\" font=\(label.font.fontName) \(r(label.font.pointSize)) color=\(label.textColor.resolvedColor(with: view.traitCollection)) lines=\(label.numberOfLines)"
    }
    if let image = view as? UIImageView {
      line += " image=\(image.image.map { "\(r($0.size.width))x\(r($0.size.height))" } ?? "nil")"
      if let configuration = image.image?.symbolConfiguration { line += " symbol=\(configuration)" }
      if let configuration = image.preferredSymbolConfiguration { line += " preferred=\(configuration)" }
      line += " tint=\(image.tintColor.resolvedColor(with: view.traitCollection))"
    }
    if let effect = view as? UIVisualEffectView { line += " effect=\(String(describing: effect.effect))" }
    report.append(line)
    for subview in view.subviews {
      dump(subview, in: window, depth: depth + 1, into: &report)
    }
  }

  private static func r(_ value: CGFloat) -> String { String(format: "%.2f", value) }

  final class MenuProvider: NSObject, UIContextMenuInteractionDelegate {
    let menu: UIMenu
    init(menu: UIMenu) { self.menu = menu }
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [menu] _ in menu }
    }
  }

  @MainActor final class Stage {
    let window: UIWindow
    let root: UIView

    init(root controller: UIViewController) throws {
      let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      window = UIWindow(windowScene: scene)
      window.rootViewController = controller
      root = controller.view
      window.makeKeyAndVisible()
    }

    init(caption: String) throws {
      let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      controller.view.backgroundColor = .systemBackground
      window.rootViewController = controller
      root = controller.view
      let label = UILabel(frame: CGRect(x: 16, y: 90, width: 360, height: 40))
      label.text = caption
      label.font = .systemFont(ofSize: 28, weight: .heavy)
      label.textColor = .systemOrange
      root.addSubview(label)
      window.makeKeyAndVisible()
    }

    func sceneWindows() throws -> [UIWindow] {
      try #require(window.windowScene).windows
    }

    func close() {
      window.isHidden = true
    }
  }
}
