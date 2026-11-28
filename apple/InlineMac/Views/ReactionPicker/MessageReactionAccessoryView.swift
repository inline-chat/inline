import AppKit
import InlineKit
import InlineMacUI
import SwiftUI

/// The reactions bar above the message context menu: the same `ReactionStrip` as the reaction overlay,
/// so it scrolls the same suggestions, sitting on the menu's glass.
///
/// + closes the menu but keeps the bar where it is and opens the full emoji picker from it, so nothing
/// jumps to another window. Takes part in the menu's input: the right-click press-drag onto an emoji,
/// and keyboard focus from the menu (↑ from the first row, ← → along, Return picks).
@MainActor
final class MessageReactionAccessoryView: NSView, ContextMenuAccessoryInteraction {
  static let size = NSSize(width: 280, height: 40)

  private let model: ReactionStripModel
  private var hosting: NSHostingView<AnyView>!
  /// The bar after + closed the menu around it, while the full picker is open.
  private var detached: ContextMenuDetachedAccessory?

  init(fullMessage: FullMessage) {
    model = ReactionStripModel(fullMessage: fullMessage)
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    let strip = ReactionStrip(
      model: model,
      pickerEdge: .minY,
      allowsEditingSuggestions: false,
      onPick: { [weak self] emoji in self?.pick(emoji) },
      onMore: { [weak self] in self?.detachFromMenu() },
      onPickerDismissed: { [weak self] in self?.closeDetached() }
    )
    .frame(width: Self.size.width, height: Self.size.height)
    hosting = NSHostingView(rootView: AnyView(strip))
    hosting.frame = bounds
    hosting.autoresizingMask = [.width, .height]
    addSubview(hosting)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var fittingSize: NSSize { Self.size }

  // MARK: Actions

  private func pick(_ emoji: String) {
    MessageReactionActions.toggle(emoji, on: model.fullMessage, messageEmojis: model.messageEmojis)
    if let detached {
      self.detached = nil
      detached.close()
    } else {
      ContextMenu.current?.close(animated: true, reason: .action)
    }
  }

  private func detachFromMenu() {
    guard detached == nil else { return }
    detached = ContextMenu.current?.closeMenuKeepingAccessory()
  }

  private func closeDetached() {
    detached?.close()
    detached = nil
  }

  private func activate(_ key: String) -> Bool {
    if key == ReactionStripModel.moreKey {
      model.focusedKey = nil
      model.pointerKey = nil
      detachFromMenu()
      model.isEmojiPickerPresented = true
      // The menu is closed already; nothing more for the session to do.
      return false
    }
    pick(key)
    return true
  }

  private func key(atScreen point: NSPoint) -> String? {
    guard let window else { return nil }
    // NSHostingView is flipped, so this is the strip's top-left space.
    let local = hosting.convert(window.convertPoint(fromScreen: point), from: nil)
    return model.key(at: local)
  }

  // MARK: ContextMenuAccessoryInteraction

  func contextMenuTrackPointer(atScreen point: NSPoint?) {
    let key = point.flatMap(key(atScreen:))
    if model.pointerKey != key { model.pointerKey = key }
  }

  func contextMenuRelease(atScreen point: NSPoint) -> Bool {
    model.pointerKey = nil
    guard let key = key(atScreen: point) else { return false }
    return activate(key)
  }

  func contextMenuSetKeyboardFocus(_ focused: Bool) -> Bool {
    model.focusedKey = focused ? model.keys.first : nil
    return true
  }

  func contextMenuMoveKeyboardFocus(by step: Int) {
    let keys = model.keys
    let index = model.focusedKey.flatMap { keys.firstIndex(of: $0) } ?? 0
    model.focusedKey = keys[min(max(index + step, 0), keys.count - 1)]
  }

  func contextMenuActivateKeyboardFocus() -> Bool {
    guard let key = model.focusedKey else { return false }
    return activate(key)
  }
}
