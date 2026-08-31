import AppKit
import SwiftUI

// Only data and list-row rendering are stand-ins. The runner compiles the real
// menu, completion surface, and emoji collection item without loading Inline.
enum ComposeAutocompleteKind { case emoji, thread }
struct ComposeAutocompleteItem: Equatable {
  let kind: ComposeAutocompleteKind
  let title: String
  var emoji: String? { kind == .emoji ? "📎" : nil }
}
struct ComposeAutocompleteMatch { let kind: ComposeAutocompleteKind }
struct ComposeAutocompletePresentationSession {
  init(match: ComposeAutocompleteMatch) {}
}
final class ComposeAutocompleteMenuItem: NSTableCellView {
  var isSelected = false
  func configure(with item: ComposeAutocompleteItem) {}
}
extension NSColor {
  func resolvedColor(with appearance: NSAppearance) -> NSColor {
    var resolved = self
    appearance.performAsCurrentDrawingAppearance {
      resolved = usingType(.componentBased) ?? usingColorSpace(.deviceRGB) ?? self
    }
    return resolved
  }
}

private final class SelectionProbe: ComposeAutocompleteMenuDelegate {
  var selectedItem: ComposeAutocompleteItem?
  func autocompleteMenu(_ menu: ComposeAutocompleteMenu, didSelect item: ComposeAutocompleteItem) {
    selectedItem = item
  }
  func autocompleteMenuDidRequestClose(_ menu: ComposeAutocompleteMenu) {}
}

@MainActor
private final class ChatLayoutProbe: NSViewController {
  let composer = NSView()
  let pill = NSView()
  let inset: CGFloat
  let completion: ComposeAutocompleteMenu
  let selection = SelectionProbe()

  init(inset: CGFloat, surface: ComposeCompletionSurfaceStyle) {
    self.inset = inset
    completion = ComposeAutocompleteMenu(surfaceStyle: surface)
    super.init(nibName: nil, bundle: nil)
    completion.delegate = selection
  }
  required init?(coder: NSCoder) { fatalError("unused") }

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    composer.translatesAutoresizingMaskIntoConstraints = false
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(composer)
    composer.addSubview(pill)
    NSLayoutConstraint.activate([
      composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      composer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      composer.heightAnchor.constraint(equalToConstant: 48),
      pill.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: inset),
      pill.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -inset),
      pill.topAnchor.constraint(equalTo: composer.topAnchor),
      pill.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -14),
    ])
  }

  func attachCompletion() {
    completion.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(completion)
    NSLayoutConstraint.activate([
      completion.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
      completion.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
      completion.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -12),
    ])
  }

  func present(kind: ComposeAutocompleteKind, count: Int) {
    completion.update(
      items: (0..<count).map { ComposeAutocompleteItem(kind: kind, title: "Item \($0)") },
      selectedIndex: 0,
      match: ComposeAutocompleteMatch(kind: kind)
    )
    completion.show(animated: false)
  }
}

private struct ChatLayoutRoute: NSViewControllerRepresentable {
  let controller: ChatLayoutProbe
  func makeNSViewController(context: Context) -> ChatLayoutProbe { controller }
  func updateNSViewController(_ controller: ChatLayoutProbe, context: Context) {}
}

@main
@MainActor
private struct ComposeLayoutChecks {
  private static var checks = 0
  private static var failures = 0

  private static func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
      failures += 1
      print("FAIL: \(label)")
    }
  }

  private static func settle(_ window: NSWindow) {
    for _ in 0..<8 {
      window.contentView?.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
    }
  }

  private static func geometry(_ probe: ChatLayoutProbe, _ width: CGFloat, _ label: String) {
    check(abs(probe.view.frame.width - width) < 0.5, "\(label): chat width \(probe.view.frame.width), expected \(width)")
    check(abs(probe.view.frame.height - 600) < 0.5, "\(label): chat height")
    check(abs(probe.composer.frame.width - width) < 0.5, "\(label): composer width")
    check(abs(probe.pill.frame.width - (width - probe.inset * 2)) < 0.5, "\(label): pill width")
    check(abs(probe.completion.frame.width - probe.pill.frame.width) < 0.5, "\(label): menu follows pill")
    check(abs(probe.completion.frame.minX - probe.inset) < 0.5, "\(label): menu leading alignment")
  }

  private static func selectedEmojiVisible(_ probe: ChatLayoutProbe, index: Int, label: String) {
    let collection = probe.completion.subviews
      .compactMap { ($0 as? NSScrollView)?.documentView as? NSCollectionView }.first
    let frame = collection?.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
    check(frame != nil, "\(label): selected emoji has layout attributes")
    if let collection, let frame {
      let visible = frame.intersection(collection.visibleRect)
      check(visible.width >= frame.width - 0.5, "\(label): selected emoji horizontally visible; item=\(frame) viewport=\(collection.visibleRect) document=\(collection.frame)")
      check(visible.height >= frame.height - 0.5, "\(label): selected emoji vertically visible; item=\(frame) viewport=\(collection.visibleRect)")
    }
  }

  private static func run(inset: CGFloat, surface: ComposeCompletionSurfaceStyle, name: String) {
    let probe = ChatLayoutProbe(inset: inset, surface: surface)
    let hosting = NSHostingController(rootView: ChatLayoutRoute(controller: probe)
      .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity))
    hosting.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = hosting
    window.setContentSize(NSSize(width: 800, height: 600))
    settle(window)
    probe.attachCompletion()
    // Match production: update immediately after attachment, before the menu's first layout.
    probe.present(kind: .emoji, count: 20)
    settle(window)
    geometry(probe, 800, "\(name) first emoji presentation")
    selectedEmojiVisible(probe, index: 0, label: "\(name) first emoji presentation")
    check(probe.completion.isVisible, "\(name): emoji visible")
    check(abs(probe.completion.frame.height - 42) < 0.5, "\(name): palette height")
    probe.present(kind: .emoji, count: 1)
    settle(window)
    geometry(probe, 800, "\(name) filtered to one emoji")

    window.setContentSize(NSSize(width: 960, height: 600))
    settle(window)
    geometry(probe, 960, "\(name) resized while visible")
    probe.completion.hide(animated: false)
    window.setContentSize(NSSize(width: 360, height: 600))
    settle(window)
    geometry(probe, 360, "\(name) resized while hidden")
    // Production resets selection on a new match, then arrows select loaded items.
    probe.present(kind: .emoji, count: 20)
    settle(window)
    probe.completion.setSelectedIndex(19)
    settle(window)
    geometry(probe, 360, "\(name) reopened at narrow width")
    check(probe.completion.selectCurrentItem(), "\(name): keyboard selection accepted")
    check(probe.selection.selectedItem?.title == "Item 19", "\(name): selected emoji reaches delegate")
    // Horizontal scroll visibility still needs a visible-window acceptance pass;
    // scrollToItems leaves this invisible window's viewport unchanged even before the fix.

    probe.completion.hide(animated: false)
    probe.present(kind: .thread, count: 12)
    settle(window)
    probe.completion.setSelectedIndex(11)
    settle(window)
    geometry(probe, 360, "\(name) thread suggestions")
    check(abs(probe.completion.frame.height - 184) < 0.5, "\(name): list height capped")
    let table = probe.completion.subviews
      .compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first
    check(table?.selectedRow == 11, "\(name): requested list selection retained")
    if let table {
      check(abs((table.tableColumns.first?.width ?? 0) - probe.completion.bounds.width) < 0.5,
        "\(name): list column follows resolved menu width")
      let row = table.rect(ofRow: 11)
      check(row.intersection(table.visibleRect).height >= row.height - 0.5, "\(name): selected list row visible")
    }
    probe.present(kind: .thread, count: 0)
    settle(window)
    geometry(probe, 360, "\(name) empty suggestions")
    check(!probe.completion.isVisible, "\(name): empty menu hidden")
    window.close()
  }

  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    run(inset: 62, surface: .glass, name: "glass side controls")
    run(inset: 0, surface: .glass, name: "glass full pill")
    run(inset: 0, surface: .material, name: "legacy material")
    print("\(checks - failures)/\(checks) compose autocomplete layout checks passed against real menu source")
    if failures > 0 { exit(1) }
  }
}
